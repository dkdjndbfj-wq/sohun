// 调度任务材料需求子表 DAO（raw SQL，不走 drift 代码生成）。
//
// 管理 scheduler_task_materials 表的 CRUD：
// - 多色任务必须逐个工具匹配材料和余量，不能把多色任务压成一个
//   required_material 字段（旧 schema 的限制）。
// - 表结构在 v19 已创建（database.dart _createSchedulerTaskMaterialsTable）。
//
// 字段：scheduler_task_id + tool_index 唯一标识任务里某个挤出机。

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database.dart';
import '../models/scheduler_models.dart';

/// 调度任务材料需求 DAO。
///
/// 全部用 [customStatement] / [customSelect] / [customInsert] / [customUpdate]
/// 执行 raw SQL，与 [SchedulerDao] / [PrintQueueDao] 模式一致。
class SchedulerMaterialDao extends DatabaseAccessor<AppDatabase> {
  SchedulerMaterialDao(super.db);

  /// 插入单条材料需求。返回新插入的 id。
  Future<int> insertMaterial(
    int taskId,
    int toolIndex,
    String materialProfile,
    String materialType,
    String? colorHex,
    double estimatedGrams, {
    int? assignedConsumableId,
  }) async {
    final id = await customInsert(
      '''
      INSERT INTO scheduler_task_materials (
        scheduler_task_id, tool_index, material_profile, material_type,
        required_color_hex, estimated_grams, assigned_consumable_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable<int>(taskId),
        Variable<int>(toolIndex),
        Variable<String>(materialProfile),
        Variable<String>(materialType),
        Variable<String>(colorHex),
        Variable<double>(estimatedGrams),
        Variable<int>(assignedConsumableId),
      ],
    );
    return id;
  }

  /// 查询任务的所有材料需求（按 tool_index 升序）。
  Future<List<SchedulerTaskMaterial>> getMaterialsForTask(int taskId) async {
    final rows = await customSelect(
      'SELECT * FROM scheduler_task_materials '
      'WHERE scheduler_task_id = ? ORDER BY tool_index ASC',
      variables: [Variable<int>(taskId)],
    ).get();
    return rows.map((r) => SchedulerTaskMaterial.fromMap(r.data)).toList();
  }

  /// 删除任务的所有材料需求。
  Future<void> deleteMaterialsForTask(int taskId) async {
    await customUpdate(
      'DELETE FROM scheduler_task_materials WHERE scheduler_task_id = ?',
      variables: [Variable<int>(taskId)],
      updates: {},
    );
  }

  /// 替换任务的所有材料需求（事务：先 delete 再 insert）。
  ///
  /// 用于任务创建/更新时整体替换材料需求列表。
  Future<void> replaceMaterialsForTask(
    int taskId,
    List<SchedulerTaskMaterial> materials,
  ) async {
    await transaction(() async {
      await deleteMaterialsForTask(taskId);
      for (final m in materials) {
        await customInsert(
          '''
          INSERT INTO scheduler_task_materials (
            scheduler_task_id, tool_index, material_profile, material_type,
            required_color_hex, estimated_grams, assigned_consumable_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          variables: [
            Variable<int>(taskId),
            Variable<int>(m.toolIndex),
            Variable<String>(m.materialProfile),
            Variable<String>(m.materialType),
            Variable<String>(m.requiredColorHex),
            Variable<double>(m.estimatedGrams),
            Variable<int>(m.assignedConsumableId),
          ],
        );
      }
    });
  }

  /// 更新材料需求分配的耗材卷 id（调度器分配后回写）。
  Future<void> setAssignedConsumable(
    int materialId,
    int? consumableId,
  ) async {
    await customUpdate(
      'UPDATE scheduler_task_materials SET assigned_consumable_id = ? '
      'WHERE id = ?',
      variables: [
        Variable<int>(consumableId),
        Variable<int>(materialId),
      ],
      updates: {},
    );
  }

  /// 批量更新任务的材料需求分配（调度器原子事务内回写）。
  Future<void> setAssignedConsumablesForTask(
    int taskId,
    Map<int, int> toolIndexToConsumableId,
  ) async {
    if (toolIndexToConsumableId.isEmpty) return;
    await transaction(() async {
      for (final entry in toolIndexToConsumableId.entries) {
        await customUpdate(
          'UPDATE scheduler_task_materials SET assigned_consumable_id = ? '
          'WHERE scheduler_task_id = ? AND tool_index = ?',
          variables: [
            Variable<int>(entry.value),
            Variable<int>(taskId),
            Variable<int>(entry.key),
          ],
          updates: {},
        );
      }
    });
  }

  /// 调试日志：打印任务的所有材料需求。
  void debugPrintMaterials(int taskId) async {
    try {
      final list = await getMaterialsForTask(taskId);
      for (final m in list) {
        debugPrint(
          '[SchedulerMaterial] task=$taskId T${m.toolIndex} '
          '${m.materialType} ${m.estimatedGrams}g '
          'color=${m.requiredColorHex ?? '-'} '
          'consumable=${m.assignedConsumableId ?? '-'}',
        );
      }
    } catch (_) {
      // 调试用，吞异常
    }
  }
}
