import 'package:consumable_tracker_desktop/data/external/print_task/cloud_task_slice_enricher.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BambuCloudTask task({
    required int id,
    required String title,
    required String status,
    required String deviceId,
    required DateTime startTime,
    double weight = 0,
    int length = 0,
    List<BambuCloudTaskFilament> filaments = const [],
  }) {
    return BambuCloudTask(
      id: id,
      title: title,
      status: status,
      startTime: startTime,
      weight: weight,
      length: length,
      costTime: 3600,
      deviceId: deviceId,
      deviceModel: 'A1',
      deviceName: 'Printer',
      amsFilaments: filaments,
    );
  }

  test('只匹配同一打印机的最新活跃任务并优先匹配任务名', () {
    final now = DateTime(2026, 8, 2, 12);
    final selected = findActiveCloudTaskForPrinter(
      tasks: [
        task(
          id: 1,
          title: 'wrong',
          status: '2',
          deviceId: 'SERIAL-A',
          startTime: now,
          weight: 10,
        ),
        task(
          id: 2,
          title: '所有配件-自由搭配',
          status: '2',
          deviceId: 'SERIAL-A',
          startTime: now.subtract(const Duration(minutes: 1)),
          weight: 20,
        ),
        task(
          id: 3,
          title: '所有配件-自由搭配',
          status: '4',
          deviceId: 'SERIAL-A',
          startTime: now,
          weight: 30,
        ),
      ],
      serial: 'serial-a',
      taskName: '所有配件-自由搭配.3mf',
    );

    expect(selected?.id, 2);
  });

  test('无 AMS 的 A1 将多材料任务统一映射到外置通道 0', () {
    final cloud = task(
      id: 1,
      title: '双色模型',
      status: '2',
      deviceId: 'A1',
      startTime: DateTime(2026),
      weight: 30,
      length: 9000,
      filaments: const [
        BambuCloudTaskFilament(
          ams: 255,
          sourceColor: 'FF0000FF',
          filamentId: 'GFA00',
          filamentType: 'PLA',
          weight: 10,
        ),
        BambuCloudTaskFilament(
          ams: 254,
          sourceColor: '00FF00FF',
          filamentId: 'GFA01',
          filamentType: 'PETG',
          weight: 20,
        ),
      ],
    );

    final slice = cloudTaskToSliceResult(
      task: cloud,
      fallbackPath: 'screen_task',
      fallbackTaskName: 'fallback',
      hasAms: false,
      totalLayers: 120,
    );

    expect(slice, isNotNull);
    expect(slice!.totalGrams, closeTo(30, 0.001));
    expect(slice.totalLengthMm, closeTo(9000, 0.001));
    expect(slice.amsMapping, [0, 0]);
    expect(slice.totalLayers, 120);
    expect(slice.filaments.first.colorHex, '#FF0000');
  });

  test('多 AMS 任务保留云端全局槽位映射', () {
    final cloud = task(
      id: 1,
      title: 'Multi AMS',
      status: 'printing',
      deviceId: 'X1',
      startTime: DateTime(2026),
      weight: 16,
      filaments: const [
        BambuCloudTaskFilament(
          ams: 6,
          sourceColor: 'FFFFFF',
          filamentId: 'GFA00',
          filamentType: 'PLA',
          weight: 8,
        ),
        BambuCloudTaskFilament(
          ams: 12,
          sourceColor: '000000',
          filamentId: 'GFA00',
          filamentType: 'PLA',
          weight: 8,
        ),
      ],
    );

    final slice = cloudTaskToSliceResult(
      task: cloud,
      fallbackPath: 'multi.3mf',
      fallbackTaskName: 'multi',
      hasAms: true,
    );

    expect(slice?.amsMapping, [6, 12]);
  });
}
