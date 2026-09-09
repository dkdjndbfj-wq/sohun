import '../../data/database/daos/print_queue_dao.dart';
import '../../data/database/daos/studio_dao.dart';
import '../../data/database/database.dart';
import '../../data/database/models/print_queue_item.dart';

class StudioPlateDispatchRequest {
  const StudioPlateDispatchRequest({
    required this.productionPlateId,
    required this.printerId,
    required this.printerSerial,
    required this.runs,
    required this.gcodePath,
    required this.filename,
    required this.artifactSha256,
    required this.consumableByTool,
    required this.printerChannelByTool,
    this.amsMapping,
  });

  final String productionPlateId;
  final int printerId;
  final String printerSerial;
  final int runs;
  final String gcodePath;
  final String filename;
  final String artifactSha256;
  final Map<int, int> consumableByTool;
  final Map<int, int> printerChannelByTool;
  final List<int>? amsMapping;
}

class StudioPlateDispatchResult {
  const StudioPlateDispatchResult({
    required this.workOrderIds,
    required this.queueIds,
  });

  final List<String> workOrderIds;
  final List<int> queueIds;
}

/// Coordinates the local database half of farm dispatch.
///
/// No printer/network side effect occurs in this service. All work-order
/// splitting, material reservations and queue inserts commit together; only
/// after this returns may the caller ask a queue notifier to start its head.
class StudioDispatchService {
  const StudioDispatchService({
    required AppDatabase database,
    required StudioDao studioDao,
    required PrintQueueDao printQueueDao,
  })  : _database = database,
        _studioDao = studioDao,
        _printQueueDao = printQueueDao;

  final AppDatabase _database;
  final StudioDao _studioDao;
  final PrintQueueDao _printQueueDao;

  Future<StudioPlateDispatchResult> dispatchPlateRuns(
    StudioPlateDispatchRequest request,
  ) async {
    if (request.runs <= 0) {
      throw ArgumentError.value(request.runs, 'runs', '排产份数必须大于 0');
    }
    if (request.artifactSha256.trim().isEmpty) {
      throw StateError('切片文件没有稳定哈希，不能排产');
    }
    final result = await _database.transaction(() async {
      final workOrderIds = await _studioDao.assignPlateRuns(
        productionPlateId: request.productionPlateId,
        printerId: request.printerId,
        runs: request.runs,
        notify: false,
      );
      final queueIds = <int>[];
      for (final workOrderId in workOrderIds) {
        await _studioDao.reserveWorkOrderMaterials(
          workOrderId: workOrderId,
          consumableByTool: request.consumableByTool,
          printerChannelByTool: request.printerChannelByTool,
          notify: false,
        );
        queueIds.add(
          await _printQueueDao.enqueue(
            PrintQueueItem(
              printerSerial: request.printerSerial,
              gcodePath: request.gcodePath,
              filename: request.filename,
              queuedAt: DateTime.now(),
              artifactSha256: request.artifactSha256,
              amsMapping: request.amsMapping,
              studioWorkOrderId: workOrderId,
            ),
            notify: false,
          ),
        );
        await _studioDao.updateWorkOrderQueueStatus(
          workOrderId,
          StudioWorkOrderStatus.assigned,
          notify: false,
        );
      }
      return StudioPlateDispatchResult(
        workOrderIds: List.unmodifiable(workOrderIds),
        queueIds: List.unmodifiable(queueIds),
      );
    });
    _studioDao.notifyChanged();
    _printQueueDao.notifyChanged();
    return result;
  }

  /// Cancels a never-started queue row and restores its quantity to the plate.
  Future<void> withdrawAssignedRun(String workOrderId) async {
    await _database.transaction(() async {
      final queueItem =
          await _printQueueDao.getByStudioWorkOrderId(workOrderId);
      if (queueItem != null && queueItem.status != PrintQueueStatus.cancelled) {
        if (queueItem.status == PrintQueueStatus.printing ||
            queueItem.status == PrintQueueStatus.waitingRemoval ||
            queueItem.status == PrintQueueStatus.completed) {
          throw StateError('已经开始或完成的打印任务不能撤回排产');
        }
        await _printQueueDao.setStatus(
          queueItem.id!,
          PrintQueueStatus.cancelled,
          notify: false,
        );
      }
      await _studioDao.withdrawAssignedPlateRun(
        workOrderId: workOrderId,
        notify: false,
      );
    });
    _studioDao.notifyChanged();
    _printQueueDao.notifyChanged();
  }
}
