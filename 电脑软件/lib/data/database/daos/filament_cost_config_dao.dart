import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database.dart';
import '../models/filament_cost_config.dart';

export '../models/filament_cost_config.dart' show FilamentCostConfig;

/// 耗材成本配置数据访问层。所有 CRUD 通过 raw SQL 实现。
///
/// 业务规则：同一品牌 + 材质 + 颜色 统一一个每公斤成本价。
/// 用户管理一份 (vendor, materialType, colorHex) → costPerKg 的映射表，
/// 切片解析时按 G-code 读到的耗材元信息匹配单价计算成本。
///
/// 匹配优先级（[matchCost]）：
/// 1. 精确匹配 vendor + materialType + colorHex
/// 2. 退化匹配 vendor + materialType + 任意颜色（colorHex='' 的通配配置）
/// 3. 进一步退化 vendor='' + materialType + colorHex=''（材质通配）
/// 4. 都没找到返回 null（UI 显示"未配置"）
class FilamentCostConfigDao extends DatabaseAccessor<AppDatabase> {
  FilamentCostConfigDao(super.db);

  // 全局变更广播。任何 CRUD 后调用 _emit()，所有 watch 流都会收到最新结果。
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// 获取全部配置（按材质+颜色排序，便于 UI 分组展示）
  Future<List<FilamentCostConfig>> getAll() async {
    final rows = await customSelect(
      'SELECT * FROM filament_cost_configs '
      'ORDER BY material_type ASC, color_hex ASC, vendor ASC',
    ).get();
    return rows.map(_rowToConfig).toList();
  }

  /// 监听全部配置流（UI 列表用）。
  ///
  /// 先发射一次当前数据（避免 UI 一直 loading），然后监听变更流。
  /// 之前用 `_changeController.stream.asyncMap` 会导致初始不发射数据，
  /// 页面打开后一直停在 loading 状态（广播流初始不发数据）。
  ///
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<List<FilamentCostConfig>> watchAll() async* {
    // 1. 先发射当前数据
    yield await getAll();
    // 2. 监听变更流，每次变更后重新查询并发射
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await getAll();
        } catch (e) {
          debugPrint('[FilamentCostConfigDao] watchAll 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[FilamentCostConfigDao] watchAll 流异常: $e');
    }
  }

  /// 获取单条配置。
  Future<FilamentCostConfig?> getById(int id) async {
    final rows = await customSelect(
      'SELECT * FROM filament_cost_configs WHERE id = ?',
      variables: [Variable(id)],
    ).get();
    return rows.isEmpty ? null : _rowToConfig(rows.first);
  }

  /// 新增配置。返回新插入的 id。
  /// 若 (vendor, materialType, colorHex) 已存在，先删除旧记录再插入（业务唯一约束）。
  /// 修复：DELETE+INSERT 用事务包裹，避免中途失败导致配置数据丢失。
  Future<int> create(FilamentCostConfig config) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return transaction(() async {
      // 先删同键旧记录，保证 (vendor, materialType, colorHex) 唯一
      await customStatement(
        'DELETE FROM filament_cost_configs '
        'WHERE vendor = ? AND material_type = ? AND color_hex = ?',
        [
          config.vendor,
          config.materialType,
          config.colorHex,
        ],
      );
      final id = await customInsert(
        '''
        INSERT INTO filament_cost_configs (
          vendor, material_type, color_hex, cost_per_kg, note, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        variables: [
          Variable(config.vendor),
          Variable(config.materialType),
          Variable(config.colorHex),
          Variable(config.costPerKg),
          Variable(config.note),
          Variable(now),
          Variable(now),
        ],
      );
      return id;
    }).then((id) {
      _emit();
      return id;
    });
  }

  /// 更新配置。
  /// 方法名故意不叫 update，避免和 drift 内置 `update(TableInfo)` 冲突。
  Future<int> updateConfig(FilamentCostConfig config) async {
    assert(config.id != null, '更新配置必须带 id');
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await transaction(() async {
      await customUpdate(
        'DELETE FROM filament_cost_configs '
        'WHERE vendor = ? AND material_type = ? AND color_hex = ? AND id != ?',
        variables: [
          Variable(config.vendor),
          Variable(config.materialType),
          Variable(config.colorHex),
          Variable(config.id),
        ],
      );
      return customUpdate(
        '''
        UPDATE filament_cost_configs
        SET vendor = ?, material_type = ?, color_hex = ?, cost_per_kg = ?,
            note = ?, updated_at = ?
        WHERE id = ?
        ''',
        variables: [
          Variable(config.vendor),
          Variable(config.materialType),
          Variable(config.colorHex),
          Variable(config.costPerKg),
          Variable(config.note),
          Variable(now),
          Variable(config.id),
        ],
      );
    });
    _emit();
    return rows;
  }

  /// 删除配置。
  /// 方法名故意不叫 delete，避免和 drift 内置 `delete(TableInfo)` 冲突。
  Future<int> deleteConfig(int id) async {
    final result = await customUpdate(
      'DELETE FROM filament_cost_configs WHERE id = ?',
      variables: [Variable(id)],
    );
    _emit();
    return result;
  }

  /// 按 (vendor, materialType, colorHex) 三级匹配单价。
  ///
  /// 匹配优先级：
  /// 1. vendor + materialType + colorHex 全匹配
  /// 2. vendor + materialType + colorHex=''（颜色通配）
  /// 3. vendor='' + materialType + colorHex=''（品牌通配）
  /// 4. vendor + materialType 任意 + colorHex 任意（只按材质匹配，最宽松）
  ///
  /// 任一参数为空串表示用户未提供，按通配处理。
  /// 返回匹配到的配置；都未匹配返回 null。
  Future<FilamentCostConfig?> matchCost({
    required String vendor,
    required String materialType,
    required String colorHex,
  }) async {
    final vendors = _vendorKeys(vendor);
    final normalizedColor = colorHex.trim().toUpperCase().replaceFirst('#', '');
    for (final vendorKey in vendors) {
      final exact = await customSelect(
        'SELECT * FROM filament_cost_configs '
        "WHERE LOWER(REPLACE(TRIM(vendor), ' ', '')) = ? "
        'AND LOWER(TRIM(material_type)) = LOWER(TRIM(?)) '
        "AND REPLACE(UPPER(TRIM(color_hex)), '#', '') = ? LIMIT 1",
        variables: [
          Variable(vendorKey),
          Variable(materialType),
          Variable(normalizedColor),
        ],
      ).getSingleOrNull();
      if (exact != null) return _rowToConfig(exact);

      final brandMaterial = await customSelect(
        'SELECT * FROM filament_cost_configs '
        "WHERE LOWER(REPLACE(TRIM(vendor), ' ', '')) = ? "
        'AND LOWER(TRIM(material_type)) = LOWER(TRIM(?)) '
        "AND TRIM(color_hex) = '' LIMIT 1",
        variables: [Variable(vendorKey), Variable(materialType)],
      ).getSingleOrNull();
      if (brandMaterial != null) return _rowToConfig(brandMaterial);
    }
    final generic = await customSelect(
      'SELECT * FROM filament_cost_configs '
      "WHERE TRIM(vendor) = '' "
      'AND LOWER(TRIM(material_type)) = LOWER(TRIM(?)) '
      "AND TRIM(color_hex) = '' LIMIT 1",
      variables: [Variable(materialType)],
    ).getSingleOrNull();
    return generic == null ? null : _rowToConfig(generic);
  }

  List<String> _vendorKeys(String value) {
    final key = value.trim().toLowerCase().replaceAll(' ', '');
    if (key.isEmpty) return const [''];
    if (key == '拓竹' || key == 'bambu' || key == 'bambulab') {
      return const ['拓竹', 'bambu', 'bambulab'];
    }
    return [key];
  }

  /// 释放资源（数据库关闭时调用）。
  void dispose() {
    _changeController.close();
  }

  /// 把 SQLite 行映射为 [FilamentCostConfig] 对象。
  FilamentCostConfig _rowToConfig(QueryRow row) {
    final createdMs = row.read<int>('created_at');
    final updatedMs = row.read<int>('updated_at');
    return FilamentCostConfig(
      id: row.read<int?>('id'),
      vendor: row.read<String>('vendor'),
      materialType: row.read<String>('material_type'),
      colorHex: row.read<String>('color_hex'),
      costPerKg: row.read<double>('cost_per_kg'),
      note: row.read<String?>('note'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs),
    );
  }
}
