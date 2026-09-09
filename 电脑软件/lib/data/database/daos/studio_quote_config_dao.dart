import 'dart:async';

import 'package:drift/drift.dart';

import '../database.dart';
import '../models/studio_quote_config_models.dart';

/// CRUD for the shared pricing inputs. Values are scoped to the local studio
/// workspace so separate farm accounts never reuse one another's rates.
class StudioQuoteConfigDao extends DatabaseAccessor<AppDatabase> {
  StudioQuoteConfigDao(super.db);

  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<StudioQuoteSettings> getSettings(String workspaceId) async {
    final row = await customSelect(
      'SELECT * FROM studio_quote_settings WHERE workspace_id = ? LIMIT 1',
      variables: [Variable(workspaceId)],
    ).getSingleOrNull();
    return row == null
        ? StudioQuoteSettings.defaults(workspaceId)
        : _settings(row);
  }

  Stream<StudioQuoteSettings> watchSettings(String workspaceId) async* {
    yield await getSettings(workspaceId);
    await for (final _ in changes) {
      yield await getSettings(workspaceId);
    }
  }

  Future<void> saveSettings(StudioQuoteSettings settings) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await customInsert(
      'INSERT INTO studio_quote_settings '
      '(workspace_id, labor_rate_per_hour, electricity_rate_per_hour, '
      'risk_reserve_percent, markup_percent, packaging_cost, minimum_order_price, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(workspace_id) DO UPDATE SET '
      'labor_rate_per_hour = excluded.labor_rate_per_hour, '
      'electricity_rate_per_hour = excluded.electricity_rate_per_hour, '
      'risk_reserve_percent = excluded.risk_reserve_percent, '
      'markup_percent = excluded.markup_percent, packaging_cost = excluded.packaging_cost, '
      'minimum_order_price = excluded.minimum_order_price, updated_at = excluded.updated_at',
      variables: [
        Variable(settings.workspaceId),
        Variable(_nonNegative(settings.laborRatePerHour)),
        Variable(_nonNegative(settings.electricityRatePerHour)),
        Variable(_percent(settings.riskReservePercent)),
        Variable(_percent(settings.markupPercent)),
        Variable(_nonNegative(settings.packagingCost)),
        Variable(_nonNegative(settings.minimumOrderPrice)),
        Variable(now),
      ],
    );
    _emit();
  }

  Future<List<StudioMachineCostConfig>> getMachines(String workspaceId) async {
    final rows = await customSelect(
      'SELECT * FROM studio_machine_cost_configs WHERE workspace_id = ? '
      'ORDER BY active DESC, brand ASC, model ASC',
      variables: [Variable(workspaceId)],
    ).get();
    return rows.map(_machine).toList(growable: false);
  }

  Stream<List<StudioMachineCostConfig>> watchMachines(
      String workspaceId) async* {
    yield await getMachines(workspaceId);
    await for (final _ in changes) {
      yield await getMachines(workspaceId);
    }
  }

  Future<int> saveMachine(StudioMachineCostConfig config) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final brand = config.brand.trim();
    final model = config.model.trim();
    final id = await transaction(() async {
      final duplicate = await customSelect(
        'SELECT id FROM studio_machine_cost_configs '
        'WHERE workspace_id = ? AND brand = ? AND model = ? AND id != ? LIMIT 1',
        variables: [
          Variable(config.workspaceId),
          Variable(brand),
          Variable(model),
          Variable(config.id),
        ],
      ).getSingleOrNull();
      final targetId = duplicate?.read<int>('id') ?? config.id;
      if (targetId == 0) {
        return customInsert(
          'INSERT INTO studio_machine_cost_configs '
          '(workspace_id, brand, model, wear_cost_per_hour, note, active, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(config.workspaceId),
            Variable(brand),
            Variable(model),
            Variable(_nonNegative(config.wearCostPerHour)),
            Variable(_nullable(config.note)),
            Variable(config.active ? 1 : 0),
            Variable(now),
          ],
        );
      }
      await customUpdate(
        'UPDATE studio_machine_cost_configs SET brand = ?, model = ?, '
        'wear_cost_per_hour = ?, note = ?, active = ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable(brand),
          Variable(model),
          Variable(_nonNegative(config.wearCostPerHour)),
          Variable(_nullable(config.note)),
          Variable(config.active ? 1 : 0),
          Variable(now),
          Variable(targetId),
        ],
      );
      if (config.id != 0 && config.id != targetId) {
        await customUpdate(
          'DELETE FROM studio_machine_cost_configs WHERE id = ?',
          variables: [Variable(config.id)],
        );
      }
      return targetId;
    });
    _emit();
    return id;
  }

  Future<void> deleteMachine(int id) async {
    await customUpdate(
      'DELETE FROM studio_machine_cost_configs WHERE id = ?',
      variables: [Variable(id)],
    );
    _emit();
  }

  Future<StudioMachineCostConfig?> matchMachine({
    required String workspaceId,
    required String? brand,
    required String? model,
  }) async {
    final cleanBrand = brand?.trim() ?? '';
    final cleanModel = model?.trim() ?? '';
    final queries = <String, List<Variable>>{
      'brand = ? AND model = ?': [Variable(cleanBrand), Variable(cleanModel)],
      'brand = ? AND model = \'\'': [Variable(cleanBrand)],
      'brand = \'\' AND model = \'\'': const [],
    };
    for (final entry in queries.entries) {
      final row = await customSelect(
        'SELECT * FROM studio_machine_cost_configs WHERE workspace_id = ? '
        'AND active = 1 AND ${entry.key} LIMIT 1',
        variables: [Variable(workspaceId), ...entry.value],
      ).getSingleOrNull();
      if (row != null) return _machine(row);
    }
    return null;
  }

  StudioQuoteSettings _settings(QueryRow row) => StudioQuoteSettings(
        id: row.read<int>('id'),
        workspaceId: row.read<String>('workspace_id'),
        laborRatePerHour: row.read<double>('labor_rate_per_hour'),
        electricityRatePerHour: row.read<double>('electricity_rate_per_hour'),
        riskReservePercent: row.read<double>('risk_reserve_percent'),
        markupPercent: row.read<double>('markup_percent'),
        packagingCost: row.read<double>('packaging_cost'),
        minimumOrderPrice: row.read<double>('minimum_order_price'),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at')),
      );

  StudioMachineCostConfig _machine(QueryRow row) => StudioMachineCostConfig(
        id: row.read<int>('id'),
        workspaceId: row.read<String>('workspace_id'),
        brand: row.read<String>('brand'),
        model: row.read<String>('model'),
        wearCostPerHour: row.read<double>('wear_cost_per_hour'),
        active: row.read<int>('active') == 1,
        note: row.read<String?>('note'),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at')),
      );

  double _nonNegative(double value) => value.isFinite && value >= 0 ? value : 0;
  double _percent(double value) => value.isFinite ? value.clamp(0, 100) : 0;
  String? _nullable(String? value) =>
      value?.trim().isEmpty == true ? null : value?.trim();

  void dispose() => _changes.close();
}
