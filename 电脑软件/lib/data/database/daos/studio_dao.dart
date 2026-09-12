import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../models/studio_models.dart';
import '../../external/slicer/production_package_inspector.dart';
import '../../../core/constants/personal_spool_policy.dart';

export '../models/studio_models.dart';

// Thumbnail blobs are revisited whenever the consolidated studio snapshot is
// refreshed (for example after a queue update). Keep the decoded bytes by
// plate + blob fingerprint so a refresh does not repeatedly base64-decode the
// same image on the UI isolate.
final Map<String, Uint8List> _studioThumbnailCache = <String, Uint8List>{};

Uint8List? _decodeStudioThumbnail(String plateId, String? encoded) {
  if (encoded == null || encoded.isEmpty) return null;
  final fingerprint =
      '$plateId:${encoded.length}:${encoded.codeUnitAt(0)}:${encoded.codeUnitAt(encoded.length - 1)}';
  final cached = _studioThumbnailCache[fingerprint];
  if (cached != null) return cached;
  try {
    final decoded = Uint8List.fromList(base64Decode(encoded));
    _studioThumbnailCache[fingerprint] = decoded;
    if (_studioThumbnailCache.length > 120) {
      _studioThumbnailCache.remove(_studioThumbnailCache.keys.first);
    }
    return decoded;
  } catch (_) {
    return null;
  }
}

class StudioDao extends DatabaseAccessor<AppDatabase> {
  StudioDao(
    super.db, {
    String? accountScope,
    String? remoteWorkspaceId,
    bool? farmInventory,
    this.actor = const StudioActivityActor(
      displayName: '管理员',
      identity: 'administrator',
    ),
  }) : _accountScope = accountScope,
       _remoteWorkspaceId = remoteWorkspaceId,
       _farmInventoryOverride = farmInventory;

  static const _uuid = Uuid();
  static const double _farmRollGrams = personalSpoolCapacityGrams;

  /// The selected production plate follows its work order into the queue.
  /// Do not silently send plate 1 from a shared multi-plate 3MF.
  Future<int?> getWorkOrderPlateIndex(String workOrderId) async {
    final row = await customSelect(
      'SELECT p.plate_index FROM studio_work_orders w '
      'JOIN studio_production_plates p ON p.id = w.production_plate_id '
      'WHERE w.id = ?',
      variables: [Variable(workOrderId)],
    ).getSingleOrNull();
    return row?.read<int>('plate_index');
  }

  final StudioActivityActor actor;
  String? _accountScope;
  String? _remoteWorkspaceId;
  final bool? _farmInventoryOverride;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Production orders are shared by the personal and farm workspaces, but
  /// their inventory is deliberately isolated.  The app provider passes the
  /// product mode explicitly; account/remote scopes remain a compatibility
  /// fallback for direct DAO callers.  Keeping this fact in the DAO prevents
  /// the personal print flow from accidentally querying only farm stock when
  /// it reserves or settles a work order.
  bool get _usesFarmInventory =>
      _farmInventoryOverride ??
      (_remoteWorkspaceId != null ||
          _accountScope?.contains('|farm') == true ||
          // Keep the direct DAO constructor's historical farm default for
          // callers/tests that do not provide an account scope.  The app
          // provider always passes the explicit product mode below, so a
          // signed-out personal app still uses personal inventory.
          _accountScope == null);

  String _inventoryWhere(String workspaceId) => _usesFarmInventory
      ? "inventory_scope = 'farm' AND farm_workspace_id = ?"
      : "inventory_scope = 'personal'";

  List<Variable> _inventoryVariables(String workspaceId) =>
      _usesFarmInventory ? [Variable(workspaceId)] : const [];

  Stream<void> get onChange => _changes.stream;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Publishes one consolidated snapshot after a larger caller-owned
  /// transaction commits successfully.
  void notifyChanged() => _emit();

  Future<String> recordActivity({
    required String workspaceId,
    required String actionCode,
    required String entityType,
    required String entityId,
    required String summary,
    bool notify = true,
  }) async {
    final id = _uuid.v4();
    await customInsert(
      'INSERT INTO studio_activity_events '
      '(id, workspace_id, actor_member_id, actor_display_name, actor_identity, '
      'action_code, entity_type, entity_id, summary, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable(id),
        Variable(workspaceId),
        Variable(_nullable(actor.memberId)),
        Variable(actor.displayName.trim().isEmpty ? '管理员' : actor.displayName),
        Variable(actor.identity == 'member' ? 'member' : 'administrator'),
        Variable(actionCode),
        Variable(entityType),
        Variable(entityId),
        Variable(summary),
        Variable(DateTime.now().millisecondsSinceEpoch),
      ],
    );
    if (notify) _emit();
    return id;
  }

  Future<String?> _workspaceIdFor(String table, String entityId) async {
    final row = await customSelect(
      'SELECT workspace_id FROM $table WHERE id = ? LIMIT 1',
      variables: [Variable(entityId)],
    ).getSingleOrNull();
    return row?.read<String>('workspace_id');
  }

  Future<int?> _localPrinterIdForRef(String? printerRef) async {
    if (printerRef == null || printerRef.isEmpty) return null;
    final rows = await customSelect(
      'SELECT id, serial FROM printers WHERE serial IS NOT NULL',
    ).get();
    for (final row in rows) {
      final serial = row.read<String?>('serial')?.trim();
      if (serial == null || serial.isEmpty) continue;
      final ref = crypto.sha256.convert(utf8.encode(serial)).toString();
      if (ref == printerRef) return row.read<int>('id');
    }
    return null;
  }

  Future<int?> _localPrinterChannelIdForRef(String? channelRef) async {
    if (channelRef == null) return null;
    final separator = channelRef.lastIndexOf(':');
    if (separator <= 0) return null;
    final channelIndex = int.tryParse(channelRef.substring(separator + 1));
    if (channelIndex == null) return null;
    final printerId = await _localPrinterIdForRef(
      channelRef.substring(0, separator),
    );
    if (printerId == null) return null;
    final row = await customSelect(
      'SELECT id FROM printer_channels WHERE printer_id = ? '
      'AND channel_index = ? LIMIT 1',
      variables: [Variable(printerId), Variable(channelIndex)],
    ).getSingleOrNull();
    return row?.read<int>('id');
  }

  Future<StudioWorkspace> ensureDefaultWorkspace() async {
    final existing = _remoteWorkspaceId != null
        ? await customSelect(
            'SELECT * FROM studio_workspaces WHERE remote_id = ? LIMIT 1',
            variables: [Variable(_remoteWorkspaceId!)],
          ).getSingleOrNull()
        : _accountScope != null
        ? await customSelect(
            'SELECT * FROM studio_workspaces WHERE account_scope = ? '
            'ORDER BY created_at ASC LIMIT 1',
            variables: [Variable(_accountScope!)],
          ).getSingleOrNull()
        : await customSelect(
            'SELECT * FROM studio_workspaces ORDER BY created_at ASC LIMIT 1',
          ).getSingleOrNull();
    if (existing != null) return _workspace(existing);

    return _createWorkspace(
      remoteId: _remoteWorkspaceId,
      accountScope: _accountScope,
    );
  }

  Future<StudioWorkspace> bindRemoteWorkspace(
    String remoteId, {
    required String accountScope,
    String? name,
  }) async {
    final normalizedRemoteId = remoteId.trim();
    if (normalizedRemoteId.isEmpty) {
      throw ArgumentError.value(remoteId, 'remoteId', '远端农场 ID 不能为空');
    }
    var existing = await customSelect(
      'SELECT * FROM studio_workspaces WHERE remote_id = ? LIMIT 1',
      variables: [Variable(normalizedRemoteId)],
    ).getSingleOrNull();
    if (existing == null) {
      await _createWorkspace(
        remoteId: normalizedRemoteId,
        accountScope: accountScope,
        name: name,
      );
    } else {
      await customUpdate(
        'UPDATE studio_workspaces SET account_scope = ?, '
        'name = CASE WHEN trim(?) = \'\' THEN name ELSE ? END '
        'WHERE id = ?',
        variables: [
          Variable(accountScope),
          Variable(name?.trim() ?? ''),
          Variable(name?.trim() ?? ''),
          Variable(existing.read<String>('id')),
        ],
      );
    }
    _remoteWorkspaceId = normalizedRemoteId;
    _accountScope = accountScope;
    existing = await customSelect(
      'SELECT * FROM studio_workspaces WHERE remote_id = ? LIMIT 1',
      variables: [Variable(normalizedRemoteId)],
    ).getSingle();
    _emit();
    return _workspace(existing);
  }

  Future<StudioWorkspace> _createWorkspace({
    String? remoteId,
    String? accountScope,
    String? name,
  }) async {
    final now = DateTime.now();
    final workspaceId = _uuid.v4();
    await transaction(() async {
      await customInsert(
        'INSERT OR IGNORE INTO studio_workspaces '
        '(id, remote_id, account_scope, name, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(workspaceId),
          Variable(_nullable(remoteId)),
          Variable(_nullable(accountScope)),
          Variable(name?.trim().isNotEmpty == true ? name!.trim() : '我的打印工作室'),
          Variable(now.millisecondsSinceEpoch),
          Variable(now.millisecondsSinceEpoch),
        ],
      );
      await customInsert(
        'INSERT OR IGNORE INTO studio_members '
        '(id, workspace_id, display_name, role, active, created_at, '
        'account_status, primary_role_code, role_codes_json) '
        "VALUES (?, ?, ?, ?, 1, ?, 'active', 'owner', '[\"owner\"]')",
        variables: [
          Variable(_uuid.v4()),
          Variable(workspaceId),
          const Variable('工作室所有者'),
          const Variable('owner'),
          Variable(now.millisecondsSinceEpoch),
        ],
      );
    });
    _emit();
    return StudioWorkspace(
      id: workspaceId,
      name: name?.trim().isNotEmpty == true ? name!.trim() : '我的打印工作室',
      remoteId: remoteId,
      createdAt: now,
      updatedAt: now,
    );
  }

  Stream<StudioSnapshot> watchDefaultSnapshot() async* {
    final workspace = await ensureDefaultWorkspace();
    yield await _fetchSnapshot(workspace.id);
    await for (final _ in _changes.stream) {
      yield await _fetchSnapshot(workspace.id);
    }
  }

  Future<StudioSnapshot> getDefaultSnapshot() async {
    final workspace = await ensureDefaultWorkspace();
    return _fetchSnapshot(workspace.id);
  }

  /// Streams the complete append-only audit trail for the current farm.
  ///
  /// The regular workspace snapshot intentionally keeps only a compact recent
  /// window for cloud payload size. The administrator audit page uses this
  /// query so older records remain reviewable on the originating database.
  Stream<List<StudioActivityEvent>> watchAllActivityEvents() async* {
    final workspace = await ensureDefaultWorkspace();
    yield await _fetchAllActivityEvents(workspace.id);
    await for (final _ in _changes.stream) {
      yield await _fetchAllActivityEvents(workspace.id);
    }
  }

  Future<void> renameWorkspace(String workspaceId, String name) async {
    await customUpdate(
      'UPDATE studio_workspaces SET name = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable(name.trim()),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(workspaceId),
      ],
    );
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'workspace.renamed',
      entityType: 'workspace',
      entityId: workspaceId,
      summary: '修改农场名称为 ${name.trim()}',
      notify: false,
    );
    _emit();
  }

  Future<void> setRemoteWorkspaceId(String workspaceId, String remoteId) async {
    final current = await customSelect(
      'SELECT remote_id FROM studio_workspaces WHERE id = ? LIMIT 1',
      variables: [Variable(workspaceId)],
    ).getSingleOrNull();
    if (current == null) throw StateError('本地农场不存在');
    final currentRemoteId = current.read<String?>('remote_id');
    if (currentRemoteId != null && currentRemoteId != remoteId) {
      throw StateError('禁止把一个本地农场重新绑定到另一个云农场');
    }
    await customUpdate(
      'UPDATE studio_workspaces SET remote_id = ?, updated_at = ? '
      'WHERE id = ? AND (remote_id IS NULL OR remote_id = ?)',
      variables: [
        Variable(remoteId),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(workspaceId),
        Variable(remoteId),
      ],
    );
    _remoteWorkspaceId = remoteId;
    _emit();
  }

  Future<String> addMember({
    required String workspaceId,
    required String displayName,
    String? email,
    StudioMemberRole role = StudioMemberRole.operator,
    String? loginName,
    String? employeeNo,
    String? phone,
    String? recoveryEmail,
    String accountStatus = 'active',
    String primaryRoleCode = 'member',
    List<String> roleCodes = const [],
    bool mustChangePassword = false,
  }) async {
    final id = _uuid.v4();
    await customInsert(
      'INSERT INTO studio_members '
      '(id, workspace_id, display_name, email, role, active, created_at, '
      'login_name, employee_no, phone, recovery_email, account_status, '
      'primary_role_code, role_codes_json, must_change_password) '
      'VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable(id),
        Variable(workspaceId),
        Variable(displayName.trim()),
        Variable(_nullable(email)),
        Variable(role.name),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(_nullable(loginName)),
        Variable(_nullable(employeeNo)),
        Variable(_nullable(phone)),
        Variable(_nullable(recoveryEmail)),
        Variable(accountStatus),
        Variable(primaryRoleCode),
        Variable(
          jsonEncode(roleCodes.isEmpty ? <String>[primaryRoleCode] : roleCodes),
        ),
        Variable(mustChangePassword ? 1 : 0),
      ],
    );
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'member.created',
      entityType: 'member',
      entityId: id,
      summary: '创建成员 ${displayName.trim()}',
      notify: false,
    );
    _emit();
    return id;
  }

  Future<void> updateMemberRole(String id, StudioMemberRole role) async {
    final workspaceId = await _workspaceIdFor('studio_members', id);
    await customUpdate(
      'UPDATE studio_members SET role = ? WHERE id = ?',
      variables: [Variable(role.name), Variable(id)],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'member.identity_updated',
        entityType: 'member',
        entityId: id,
        summary: '更新成员身份',
        notify: false,
      );
    }
    _emit();
  }

  Future<void> setMemberActive(String id, bool active) async {
    final workspaceId = await _workspaceIdFor('studio_members', id);
    await customUpdate(
      'UPDATE studio_members SET active = ? WHERE id = ?',
      variables: [Variable(active ? 1 : 0), Variable(id)],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: active ? 'member.activated' : 'member.deactivated',
        entityType: 'member',
        entityId: id,
        summary: active ? '启用成员账号' : '停用成员账号',
        notify: false,
      );
    }
    _emit();
  }

  /// Removes access without deleting the member row or any historical links.
  ///
  /// `removed` is a terminal tombstone. Keeping the row allows old work orders
  /// and audit records to retain their stable member identifier.
  Future<void> removeMemberPreservingHistory(String id) async {
    final row = await customSelect(
      'SELECT workspace_id, display_name, role FROM studio_members WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (row == null) throw StateError('成员不存在');
    if (row.read<String>('role') == StudioMemberRole.owner.name) {
      throw StateError('不能删除农场管理员');
    }
    final workspaceId = row.read<String>('workspace_id');
    final displayName = row.read<String>('display_name');
    await customUpdate(
      'UPDATE studio_members SET active = 0, account_status = ?, '
      'deactivated_at = ? WHERE id = ?',
      variables: [
        const Variable('removed'),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(id),
      ],
    );
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'member.removed',
      entityType: 'member',
      entityId: id,
      summary: '删除成员 $displayName（历史操作记录已保留）',
      notify: false,
    );
    _emit();
  }

  Future<String> addCustomer({
    required String workspaceId,
    required String name,
    String? contactName,
    String? phone,
    String? email,
    String? note,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customInsert(
      'INSERT INTO studio_customers '
      '(id, workspace_id, name, contact_name, phone, email, note, archived, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
      variables: [
        Variable(id),
        Variable(workspaceId),
        Variable(name.trim()),
        Variable(_nullable(contactName)),
        Variable(_nullable(phone)),
        Variable(_nullable(email)),
        Variable(_nullable(note)),
        Variable(now),
        Variable(now),
      ],
    );
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'customer.created',
      entityType: 'customer',
      entityId: id,
      summary: '创建订单用户 ${name.trim()}',
      notify: false,
    );
    _emit();
    return id;
  }

  Future<void> setCustomerArchived(String id, bool archived) async {
    final workspaceId = await _workspaceIdFor('studio_customers', id);
    await customUpdate(
      'UPDATE studio_customers SET archived = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable(archived ? 1 : 0),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(id),
      ],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: archived ? 'customer.archived' : 'customer.restored',
        entityType: 'customer',
        entityId: id,
        summary: archived ? '停用订单用户' : '恢复订单用户',
        notify: false,
      );
    }
    _emit();
  }

  Future<String> addOrder({
    required String workspaceId,
    required String orderNo,
    required String title,
    String? customerId,
    DateTime? dueAt,
    double totalPrice = 0,
    String? note,
    String? publicNote,
    bool portalVideoEnabled = true,
    StudioQuote? quote,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await customInsert(
        'INSERT INTO studio_orders '
        '(id, workspace_id, customer_id, order_no, title, status, due_at, total_price, note, public_note, portal_video_enabled, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(id),
          Variable(workspaceId),
          Variable(_nullable(customerId)),
          Variable(orderNo.trim()),
          Variable(title.trim()),
          const Variable('draft'),
          Variable(dueAt?.millisecondsSinceEpoch),
          Variable(totalPrice),
          Variable(_nullable(note)),
          Variable(_nullable(publicNote)),
          Variable(portalVideoEnabled ? 1 : 0),
          Variable(now),
          Variable(now),
        ],
      );
      if (quote != null) {
        await _insertQuoteRow(quote, orderIdOverride: id);
      }
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'order.created',
      entityType: 'order',
      entityId: id,
      summary: '创建订单 ${orderNo.trim()} · ${title.trim()}',
      notify: false,
    );
    if (quote != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'quote.created',
        entityType: 'quote',
        entityId: quote.id,
        summary: '创建订单报价 ${quote.quoteNo}',
        notify: false,
      );
    }
    _emit();
    return id;
  }

  Future<void> updateOrderStatus(String id, StudioOrderStatus status) async {
    final workspaceId = await _workspaceIdFor('studio_orders', id);
    await customUpdate(
      'UPDATE studio_orders SET status = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable(status.name),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(id),
      ],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'order.status_updated',
        entityType: 'order',
        entityId: id,
        summary: '更新订单状态为 ${status.name}',
        notify: false,
      );
    }
    _emit();
  }

  /// Creates the customer order, its source projects/plates/items, and the
  /// corresponding farm work orders atomically. A plate is the scheduling
  /// unit and may remain unsliced until capacity becomes available.
  Future<String> addProductionOrder({
    required String workspaceId,
    required String orderNo,
    required String title,
    required List<StudioProductionPackageDraft> packages,
    DateTime? dueAt,
    double totalPrice = 0,
    String? note,
    String? publicNote,
    bool portalVideoEnabled = true,
    StudioQuote? quote,
  }) async {
    final orderId = _uuid.v4();
    if (packages.isEmpty || packages.length > 5) {
      throw ArgumentError.value(packages.length, 'packages', '必须包含 1-5 个生产项目');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await customInsert(
        'INSERT INTO studio_orders '
        '(id, workspace_id, customer_id, order_no, title, status, due_at, total_price, note, public_note, portal_video_enabled, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(orderId),
          Variable(workspaceId),
          const Variable(null),
          Variable(orderNo.trim()),
          Variable(title.trim()),
          const Variable('production'),
          Variable(dueAt?.millisecondsSinceEpoch),
          Variable(totalPrice),
          Variable(_nullable(note)),
          Variable(_nullable(publicNote)),
          Variable(portalVideoEnabled ? 1 : 0),
          Variable(now),
          Variable(now),
        ],
      );
      for (final package in packages) {
        final packageId = _uuid.v4();
        await customInsert(
          'INSERT INTO studio_production_packages '
          '(id, workspace_id, order_id, source_name, local_path, artifact_sha256, artifact_kind, slicer_name, slicer_version, target_model, nozzle_diameter, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(packageId),
            Variable(workspaceId),
            Variable(orderId),
            Variable(package.sourceName.trim()),
            Variable(_nullable(package.localPath)),
            Variable(_nullable(package.artifactSha256)),
            Variable(package.artifactKind),
            Variable(_nullable(package.slicerName)),
            Variable(_nullable(package.slicerVersion)),
            Variable(_nullable(package.targetModel)),
            Variable(package.nozzleDiameter),
            Variable(now),
          ],
        );
        for (final plate in package.plates) {
          final plateId = _uuid.v4();
          final runs = math.max(1, plate.requiredRuns);
          await customInsert(
            'INSERT INTO studio_production_plates '
            '(id, workspace_id, order_id, package_id, plate_index, name, required_runs, estimated_seconds, estimated_grams, slice_status, slice_artifact_path, slice_artifact_sha256, slice_target_model, slice_nozzle_diameter, auto_eject_enabled, thumbnail_base64, total_layers, tool_change_count, filament_usage_json, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            variables: [
              Variable(plateId),
              Variable(workspaceId),
              Variable(orderId),
              Variable(packageId),
              Variable(plate.plateIndex),
              Variable(plate.name.trim()),
              Variable(runs),
              Variable(math.max(0, plate.estimatedSeconds)),
              Variable(math.max(0, plate.estimatedGrams)),
              Variable(plate.sliceStatus.name),
              Variable(_nullable(plate.sliceArtifactPath)),
              Variable(_nullable(plate.sliceArtifactSha256)),
              Variable(
                _nullable(plate.sliceTargetModel ?? package.targetModel),
              ),
              Variable(plate.sliceNozzleDiameter ?? package.nozzleDiameter),
              Variable(switch (plate.autoEjectEnabled) {
                true => 1,
                false => 0,
                null => null,
              }),
              Variable(
                plate.thumbnailBytes == null
                    ? null
                    : base64Encode(plate.thumbnailBytes!),
              ),
              Variable(math.max(0, plate.totalLayers)),
              Variable(math.max(0, plate.toolChangeCount)),
              Variable(_encodeFilaments(plate.filaments)),
              Variable(now),
              Variable(now),
            ],
          );
          for (final item in plate.items) {
            await customInsert(
              'INSERT INTO studio_order_items '
              '(id, workspace_id, order_id, package_id, plate_id, source_key, name, per_run_quantity, required_quantity, created_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              variables: [
                Variable(_uuid.v4()),
                Variable(workspaceId),
                Variable(orderId),
                Variable(packageId),
                Variable(plateId),
                Variable(item.sourceKey),
                Variable(item.name.trim()),
                Variable(math.max(1, item.perRunQuantity)),
                Variable(math.max(1, item.requiredQuantity)),
                Variable(now),
              ],
            );
          }

          final printers = plate.assignedPrinterIds.toSet().toList();
          final allocation = <int, int>{};
          if (printers.isEmpty) {
            allocation[0] = runs;
          } else {
            final base = runs ~/ printers.length;
            var remainder = runs % printers.length;
            for (final printerId in printers) {
              final count = base + (remainder > 0 ? 1 : 0);
              remainder -= count > base ? 1 : 0;
              if (count > 0) allocation[printerId] = count;
            }
          }
          for (final entry in allocation.entries) {
            final workOrderId = _uuid.v4();
            await customInsert(
              'INSERT INTO studio_work_orders '
              '(id, workspace_id, order_id, production_plate_id, title, quantity, completed_quantity, status, printer_id, estimated_seconds, material_cost_snapshot, quoted_price_snapshot, created_at, updated_at) '
              'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 0, 0, ?, ?)',
              variables: [
                Variable(workOrderId),
                Variable(workspaceId),
                Variable(orderId),
                Variable(plateId),
                Variable(plate.name.trim()),
                Variable(entry.value),
                Variable(
                  plate.sliceStatus == StudioPlateSliceStatus.sliced
                      ? StudioWorkOrderStatus.queued.name
                      : StudioWorkOrderStatus.paused.name,
                ),
                Variable(entry.key == 0 ? null : entry.key),
                Variable(math.max(0, plate.estimatedSeconds) * entry.value),
                Variable(now),
                Variable(now),
              ],
            );
            if (plate.sliceStatus == StudioPlateSliceStatus.sliced) {
              await _replaceWorkOrderMaterialRequirements(
                workspaceId: workspaceId,
                workOrderId: workOrderId,
                productionPlateId: plateId,
                quantity: entry.value,
                estimatedGrams: plate.estimatedGrams,
                filaments: plate.filaments,
                now: now,
              );
            }
          }
        }
      }
      if (quote != null) {
        await _insertQuoteRow(quote, orderIdOverride: orderId);
      }
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'order.production_created',
      entityType: 'order',
      entityId: orderId,
      summary: '创建生产订单 ${orderNo.trim()} · ${packages.length} 个项目',
      notify: false,
    );
    if (quote != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'quote.created',
        entityType: 'quote',
        entityId: quote.id,
        summary: '创建生产订单报价 ${quote.quoteNo}',
        notify: false,
      );
    }
    _emit();
    return orderId;
  }

  Future<String> addWorkOrder({
    required String workspaceId,
    required String orderId,
    required String title,
    required int quantity,
    int? schedulerTaskId,
    String? assignedMemberId,
    int? printerId,
    int? estimatedSeconds,
    double materialCostSnapshot = 0,
    double quotedPriceSnapshot = 0,
    String? note,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customInsert(
      'INSERT INTO studio_work_orders '
      '(id, workspace_id, order_id, scheduler_task_id, title, quantity, completed_quantity, '
      'status, assigned_member_id, printer_id, estimated_seconds, material_cost_snapshot, '
      'quoted_price_snapshot, note, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable(id),
        Variable(workspaceId),
        Variable(orderId),
        Variable(schedulerTaskId),
        Variable(title.trim()),
        Variable(math.max(1, quantity)),
        const Variable('queued'),
        Variable(_nullable(assignedMemberId)),
        Variable(printerId),
        Variable(estimatedSeconds),
        Variable(materialCostSnapshot),
        Variable(quotedPriceSnapshot),
        Variable(_nullable(note)),
        Variable(now),
        Variable(now),
      ],
    );
    await customUpdate(
      "UPDATE studio_orders SET status = 'production', updated_at = ? "
      "WHERE id = ? AND status IN ('draft', 'confirmed')",
      variables: [Variable(now), Variable(orderId)],
    );
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'work_order.created',
      entityType: 'work_order',
      entityId: id,
      summary: '创建工单 ${title.trim()} · ${math.max(1, quantity)} 份',
      notify: false,
    );
    _emit();
    return id;
  }

  /// Assigns a number of still-unstarted plate runs to one physical printer.
  ///
  /// A plate keeps one unassigned remainder work order. Assigning fewer runs
  /// splits a new printer-specific work order so the same plate can run on
  /// several printers in parallel without duplicating completed quantities.
  Future<List<String>> assignPlateRuns({
    required String productionPlateId,
    required int printerId,
    required int runs,
    bool notify = true,
  }) async {
    if (runs <= 0) throw ArgumentError.value(runs, 'runs', '分配份数必须大于 0');
    final assignedWorkOrderIds = <String>[];
    String? activityWorkspaceId;
    String? activityPlateName;
    await transaction(() async {
      final plateRow = await customSelect(
        'SELECT * FROM studio_production_plates WHERE id = ?',
        variables: [Variable(productionPlateId)],
      ).getSingleOrNull();
      if (plateRow == null) throw StateError('生产盘不存在');
      final plate = _productionPlate(plateRow);
      if (!plate.isSliced) {
        throw StateError('这一盘尚未完成切片，不能排产');
      }
      activityWorkspaceId = plate.workspaceId;
      activityPlateName = plate.name;
      final printer = await customSelect(
        'SELECT id FROM printers WHERE id = ?',
        variables: [Variable(printerId)],
      ).getSingleOrNull();
      if (printer == null) throw StateError('所选打印机不存在');
      final source = await customSelect(
        'SELECT * FROM studio_work_orders WHERE production_plate_id = ? '
        'AND printer_id IS NULL AND completed_quantity = 0 '
        "AND status IN ('queued', 'paused') AND quantity >= ? "
        'ORDER BY created_at ASC LIMIT 1',
        variables: [Variable(productionPlateId), Variable(runs)],
      ).getSingleOrNull();
      if (source == null) throw StateError('这个盘没有足够的待分配份数');
      final sourceId = source.read<String>('id');
      final sourceQuantity = source.read<int>('quantity');
      final now = DateTime.now().millisecondsSinceEpoch;
      final remainder = sourceQuantity - runs;
      if (remainder > 0) {
        await customUpdate(
          'UPDATE studio_work_orders SET quantity = ?, estimated_seconds = ?, '
          'updated_at = ? WHERE id = ?',
          variables: [
            Variable(remainder),
            Variable(math.max(0, plate.estimatedSeconds) * remainder),
            Variable(now),
            Variable(sourceId),
          ],
        );
        if (plate.isSliced) {
          await _replaceWorkOrderMaterialRequirements(
            workspaceId: plate.workspaceId,
            workOrderId: sourceId,
            productionPlateId: productionPlateId,
            quantity: remainder,
            estimatedGrams: plate.estimatedGrams,
            filaments: plate.filaments,
            now: now,
          );
        }
      }

      for (var run = 0; run < runs; run++) {
        final assignedWorkOrderId = remainder == 0 && run == 0
            ? sourceId
            : _uuid.v4();
        assignedWorkOrderIds.add(assignedWorkOrderId);
        if (assignedWorkOrderId == sourceId) {
          await customUpdate(
            'UPDATE studio_work_orders SET quantity = 1, printer_id = ?, '
            'estimated_seconds = ?, updated_at = ? WHERE id = ?',
            variables: [
              Variable(printerId),
              Variable(math.max(0, plate.estimatedSeconds)),
              Variable(now),
              Variable(sourceId),
            ],
          );
        } else {
          await customInsert(
            'INSERT INTO studio_work_orders '
            '(id, workspace_id, order_id, production_plate_id, title, quantity, '
            'completed_quantity, status, assigned_member_id, printer_id, '
            'estimated_seconds, material_cost_snapshot, quoted_price_snapshot, '
            'note, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            variables: [
              Variable(assignedWorkOrderId),
              Variable(source.read<String>('workspace_id')),
              Variable(source.read<String>('order_id')),
              Variable(productionPlateId),
              Variable(source.read<String>('title')),
              const Variable(1),
              Variable(source.read<String>('status')),
              Variable(source.read<String?>('assigned_member_id')),
              Variable(printerId),
              Variable(math.max(0, plate.estimatedSeconds)),
              Variable(source.read<double>('material_cost_snapshot')),
              Variable(source.read<double>('quoted_price_snapshot')),
              Variable(source.read<String?>('note')),
              Variable(now),
              Variable(now),
            ],
          );
        }
        if (plate.isSliced) {
          await _replaceWorkOrderMaterialRequirements(
            workspaceId: plate.workspaceId,
            workOrderId: assignedWorkOrderId,
            productionPlateId: productionPlateId,
            quantity: 1,
            estimatedGrams: plate.estimatedGrams,
            filaments: plate.filaments,
            now: now,
          );
        }
      }
      await customUpdate(
        "UPDATE studio_orders SET status = 'production', updated_at = ? "
        "WHERE id = ? AND status IN ('draft', 'confirmed')",
        variables: [Variable(now), Variable(plate.orderId)],
      );
    });
    if (activityWorkspaceId != null) {
      await recordActivity(
        workspaceId: activityWorkspaceId!,
        actionCode: 'plate.assigned',
        entityType: 'plate',
        entityId: productionPlateId,
        summary: '为 ${activityPlateName ?? '生产盘'} 分配 $runs 份打印任务',
        notify: false,
      );
      for (final workOrderId in assignedWorkOrderIds) {
        await recordActivity(
          workspaceId: activityWorkspaceId!,
          actionCode: 'work_order.assigned',
          entityType: 'work_order',
          entityId: workOrderId,
          summary: '分配到打印机 #$printerId',
          notify: false,
        );
      }
    }
    if (notify) _emit();
    return assignedWorkOrderIds;
  }

  /// Restores one never-started assigned run to the plate's unassigned pool.
  ///
  /// The original row is retained as cancelled for audit history. Its quantity
  /// is added back to an unassigned work order so it can be dispatched again.
  /// The caller must cancel any active queue row first, preferably in the same
  /// database transaction.
  Future<void> withdrawAssignedPlateRun({
    required String workOrderId,
    bool notify = true,
  }) async {
    String? workspaceId;
    String? plateId;
    String? title;
    var restoredQuantity = 0;
    await transaction(() async {
      final row = await customSelect(
        'SELECT * FROM studio_work_orders WHERE id = ?',
        variables: [Variable(workOrderId)],
      ).getSingleOrNull();
      if (row == null) throw StateError('工单不存在');
      if (row.read<int?>('printer_id') == null) {
        throw StateError('该工单尚未分配打印机');
      }
      final status = StudioWorkOrderStatus.fromCode(row.read<String>('status'));
      if (row.read<int>('completed_quantity') > 0 ||
          status == StudioWorkOrderStatus.printing ||
          status == StudioWorkOrderStatus.completed ||
          status == StudioWorkOrderStatus.cancelled) {
        throw StateError('已经开始或结束的工单不能撤回排产');
      }
      final activeQueue = await customSelect(
        'SELECT status FROM print_queue WHERE studio_work_order_id = ? '
        "AND status != 'cancelled' LIMIT 1",
        variables: [Variable(workOrderId)],
      ).getSingleOrNull();
      if (activeQueue != null) {
        throw StateError('请先取消该工单的打印队列任务');
      }
      final productionPlateId = row.read<String?>('production_plate_id');
      if (productionPlateId == null) throw StateError('该工单没有关联生产盘');
      final plate = await customSelect(
        'SELECT * FROM studio_production_plates WHERE id = ?',
        variables: [Variable(productionPlateId)],
      ).getSingleOrNull();
      if (plate == null) throw StateError('生产盘不存在');

      workspaceId = row.read<String>('workspace_id');
      plateId = productionPlateId;
      title = row.read<String>('title');
      restoredQuantity = row.read<int>('quantity');
      final now = DateTime.now().millisecondsSinceEpoch;
      final remainder = await customSelect(
        'SELECT * FROM studio_work_orders WHERE production_plate_id = ? '
        'AND id != ? AND printer_id IS NULL AND completed_quantity = 0 '
        "AND status IN ('queued', 'paused') ORDER BY created_at ASC LIMIT 1",
        variables: [Variable(productionPlateId), Variable(workOrderId)],
      ).getSingleOrNull();
      late final String remainderId;
      late final int remainderQuantity;
      if (remainder != null) {
        remainderId = remainder.read<String>('id');
        remainderQuantity = remainder.read<int>('quantity') + restoredQuantity;
        await customUpdate(
          'UPDATE studio_work_orders SET quantity = ?, estimated_seconds = ?, '
          "status = 'queued', updated_at = ? WHERE id = ?",
          variables: [
            Variable(remainderQuantity),
            Variable(
              math.max(0, plate.read<int>('estimated_seconds')) *
                  remainderQuantity,
            ),
            Variable(now),
            Variable(remainderId),
          ],
        );
      } else {
        remainderId = _uuid.v4();
        remainderQuantity = restoredQuantity;
        await customInsert(
          'INSERT INTO studio_work_orders '
          '(id, workspace_id, order_id, production_plate_id, title, quantity, '
          'completed_quantity, status, assigned_member_id, printer_id, '
          'estimated_seconds, material_cost_snapshot, quoted_price_snapshot, '
          'note, created_at, updated_at) '
          "VALUES (?, ?, ?, ?, ?, ?, 0, 'queued', ?, NULL, ?, ?, ?, ?, ?, ?)",
          variables: [
            Variable(remainderId),
            Variable(row.read<String>('workspace_id')),
            Variable(row.read<String>('order_id')),
            Variable(productionPlateId),
            Variable(row.read<String>('title')),
            Variable(remainderQuantity),
            Variable(row.read<String?>('assigned_member_id')),
            Variable(
              math.max(0, plate.read<int>('estimated_seconds')) *
                  remainderQuantity,
            ),
            Variable(row.read<double>('material_cost_snapshot')),
            Variable(row.read<double>('quoted_price_snapshot')),
            Variable(row.read<String?>('note')),
            Variable(now),
            Variable(now),
          ],
        );
      }
      await _replaceWorkOrderMaterialRequirements(
        workspaceId: row.read<String>('workspace_id'),
        workOrderId: remainderId,
        productionPlateId: productionPlateId,
        quantity: remainderQuantity,
        estimatedGrams: plate.read<double>('estimated_grams'),
        filaments: _decodeFilaments(plate.read<String>('filament_usage_json')),
        now: now,
      );
      await customUpdate(
        'UPDATE studio_work_order_materials SET reserved_grams = 0, '
        "status = 'released', updated_at = ? WHERE work_order_id = ? "
        "AND status IN ('unallocated', 'reserved')",
        variables: [Variable(now), Variable(workOrderId)],
      );
      await customUpdate(
        "UPDATE studio_work_orders SET status = 'cancelled', updated_at = ? "
        'WHERE id = ?',
        variables: [Variable(now), Variable(workOrderId)],
      );
    });
    if (workspaceId != null && plateId != null) {
      await recordActivity(
        workspaceId: workspaceId!,
        actionCode: 'work_order.assignment_withdrawn',
        entityType: 'work_order',
        entityId: workOrderId,
        summary: '撤回 ${title ?? '工单'} 的 $restoredQuantity 份排产并恢复待分配数量',
        notify: false,
      );
    }
    if (notify) _emit();
  }

  Future<void> updateWorkOrderProgress({
    required String id,
    required int completedQuantity,
    required StudioWorkOrderStatus status,
    Map<int, double>? actualGramsByTool,
  }) async {
    String? activityWorkspaceId;
    String? activityTitle;
    await transaction(() async {
      final row = await customSelect(
        'SELECT workspace_id, order_id, title, quantity, status '
        'FROM studio_work_orders WHERE id = ?',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (row == null) return;
      final quantity = row.read<int>('quantity');
      final completed = completedQuantity.clamp(0, quantity);
      final currentStatus = StudioWorkOrderStatus.fromCode(
        row.read<String>('status'),
      );
      final materialRows = await customSelect(
        'SELECT * FROM studio_work_order_materials '
        'WHERE work_order_id = ? ORDER BY tool_index',
        variables: [Variable(id)],
      ).get();
      final materials = materialRows.map(_workOrderMaterial).toList();
      final alreadySettled =
          materials.isNotEmpty && materials.every((item) => item.isSettled);
      final workspaceId = row.read<String>('workspace_id');
      activityWorkspaceId = workspaceId;
      activityTitle = row.read<String>('title');

      if (alreadySettled && status != StudioWorkOrderStatus.completed) {
        throw StateError('该工单已完成耗材结算，不能退回未完成状态');
      }
      if (status == StudioWorkOrderStatus.completed && !alreadySettled) {
        if (completed != quantity) {
          throw StateError('完成工单时，完成数量必须等于工单数量');
        }
        if (materials.any((item) => !item.isAllocated)) {
          throw StateError('请先为每个耗材通道分配库存卷，再完成工单');
        }

        final actualByMaterial = <StudioWorkOrderMaterial, double>{};
        final demandByConsumable = <int, double>{};
        var incrementalMaterialCost = 0.0;
        for (final material in materials) {
          final actual =
              actualGramsByTool?[material.toolIndex] ?? material.estimatedGrams;
          if (!actual.isFinite || actual < 0) {
            throw ArgumentError.value(
              actual,
              'actualGramsByTool',
              '实际克数必须大于等于 0',
            );
          }
          actualByMaterial[material] = actual;
          incrementalMaterialCost +=
              actual * await _farmMaterialCostPerGram(material.consumableId!);
          if (material.printerChannelId case final channelId?) {
            final available = await getPrinterChannelAvailableGrams(
              channelId,
              excludingWorkOrderId: id,
            );
            if (available + 0.0001 < actual) {
              throw StateError(
                '工具 ${material.toolIndex + 1} 所选槽位当前只剩 '
                '${available.toStringAsFixed(1)} g，无法结算 '
                '${actual.toStringAsFixed(1)} g',
              );
            }
          } else {
            // Legacy/manual work orders without a physical printer slot keep
            // the previous fallback. Normal farm production settles only the
            // independently tracked roll loaded in its AMS/external slot.
            demandByConsumable.update(
              material.consumableId!,
              (value) => value + actual,
              ifAbsent: () => actual,
            );
          }
        }

        for (final demand in demandByConsumable.entries) {
          final available = await _getConsumableAvailability(
            demand.key,
            workspaceId: workspaceId,
            excludingWorkOrderId: id,
          );
          if (available.availableGrams + 0.0001 < demand.value) {
            throw StateError(
              '耗材卷 #${demand.key} 在扣除其他任务预留后只剩 '
              '${available.availableGrams.toStringAsFixed(1)} g 可用，'
              '无法结算 ${demand.value.toStringAsFixed(1)} g',
            );
          }
          final stock = await customSelect(
            'SELECT remaining_grams FROM consumables WHERE id = ? '
            'AND ${_inventoryWhere(workspaceId)}',
            variables: [
              Variable(demand.key),
              ..._inventoryVariables(workspaceId),
            ],
          ).getSingleOrNull();
          final remaining = stock?.read<double>('remaining_grams') ?? 0;
          if (remaining + 0.0001 < demand.value) {
            throw StateError(
              '耗材卷 #${demand.key} 只剩 ${remaining.toStringAsFixed(1)} g，'
              '无法结算 ${demand.value.toStringAsFixed(1)} g',
            );
          }
          await customUpdate(
            'UPDATE consumables SET remaining_grams = remaining_grams - ?, '
            'updated_at = ? WHERE id = ? AND remaining_grams >= ? '
            'AND ${_inventoryWhere(workspaceId)}',
            variables: [
              Variable(demand.value),
              Variable(_driftNowSeconds()),
              Variable(demand.key),
              Variable(demand.value),
              ..._inventoryVariables(workspaceId),
            ],
            updates: {db.consumables},
          );
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        for (final entry in actualByMaterial.entries) {
          final material = entry.key;
          final actual = entry.value;
          await customUpdate(
            'UPDATE studio_work_order_materials SET consumed_grams = consumed_grams + ?, '
            "reserved_grams = 0, status = 'settled', settled_at = ?, updated_at = ? "
            'WHERE id = ?',
            variables: [
              Variable(actual),
              Variable(now),
              Variable(now),
              Variable(material.id),
            ],
          );
          if (material.printerChannelId case final channelId?) {
            await customUpdate(
              'UPDATE printer_channels SET loaded_remaining_grams = '
              'MAX(0, loaded_remaining_grams - ?), updated_at = ? WHERE id = ?',
              variables: [
                Variable(actual),
                Variable(_driftNowSeconds()),
                Variable(channelId),
              ],
              updates: {db.printerChannels},
            );
          }
          if (actual > 0 && material.printerChannelId == null) {
            await customInsert(
              'INSERT INTO studio_inventory_events '
              '(id, workspace_id, consumable_id, event_type, delta_grams, reason, created_at) '
              "VALUES (?, ?, ?, 'consume', ?, ?, ?)",
              variables: [
                Variable(_uuid.v4()),
                Variable(row.read<String>('workspace_id')),
                Variable(material.consumableId),
                Variable(-actual),
                Variable(
                  '${row.read<String>('title')} · 通道 ${material.toolIndex + 1} 实际用量',
                ),
                Variable(now),
              ],
            );
          }
        }
        if (incrementalMaterialCost > 0) {
          await customUpdate(
            'UPDATE studio_work_orders SET material_cost_snapshot = '
            'material_cost_snapshot + ? WHERE id = ?',
            variables: [Variable(incrementalMaterialCost), Variable(id)],
          );
        }
      } else if ((status == StudioWorkOrderStatus.cancelled ||
              status == StudioWorkOrderStatus.failed) &&
          currentStatus != StudioWorkOrderStatus.completed) {
        await customUpdate(
          'UPDATE studio_work_order_materials SET reserved_grams = 0, '
          "status = 'released', updated_at = ? "
          "WHERE work_order_id = ? AND status IN ('unallocated', 'reserved')",
          variables: [
            Variable(DateTime.now().millisecondsSinceEpoch),
            Variable(id),
          ],
        );
      }
      await customUpdate(
        'UPDATE studio_work_orders SET completed_quantity = ?, status = ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable(completed),
          Variable(status.name),
          Variable(DateTime.now().millisecondsSinceEpoch),
          Variable(id),
        ],
      );
      await _reconcileOrderStatus(row.read<String>('order_id'));
    });
    if (activityWorkspaceId != null) {
      await recordActivity(
        workspaceId: activityWorkspaceId!,
        actionCode: 'work_order.progress_updated',
        entityType: 'work_order',
        entityId: id,
        summary:
            '${activityTitle ?? '工单'}：${status.name} · 已完成 $completedQuantity',
        notify: false,
      );
    }
    _emit();
  }

  /// Queue-driven lifecycle update that deliberately does not settle material.
  Future<void> updateWorkOrderQueueStatus(
    String id,
    StudioWorkOrderStatus status, {
    bool notify = true,
  }) async {
    if (status == StudioWorkOrderStatus.completed) {
      throw ArgumentError('完成状态必须经过耗材结算');
    }
    final workspaceId = await _workspaceIdFor('studio_work_orders', id);
    await customUpdate(
      'UPDATE studio_work_orders SET status = ?, updated_at = ? '
      "WHERE id = ? AND status NOT IN ('completed', 'cancelled')",
      variables: [
        Variable(status.name),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(id),
      ],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'work_order.queue_status_updated',
        entityType: 'work_order',
        entityId: id,
        summary: '更新队列状态为 ${status.name}',
        notify: false,
      );
    }
    if (notify) _emit();
  }

  /// Unattended completion has no operator dialog, so it settles with the
  /// sliced per-tool estimates. Repeated completion remains idempotent.
  Future<void> completeWorkOrderUsingEstimate(String id) async {
    final row = await customSelect(
      'SELECT quantity FROM studio_work_orders WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (row == null) return;
    await updateWorkOrderProgress(
      id: id,
      completedQuantity: row.read<int>('quantity'),
      status: StudioWorkOrderStatus.completed,
    );
  }

  /// Records the material already consumed by a failed physical print.
  ///
  /// The loss is estimated from the printer-reported progress and is kept
  /// separate from the reservation for the next retry. [printQueueId] makes
  /// the write idempotent when the same failure notification is delivered
  /// more than once.
  Future<double> recordFailedWorkOrderAttemptUsingEstimate({
    required String id,
    required int printQueueId,
    required int attemptNo,
    int? progressPercent,
    String? printerSerial,
    DateTime? startedAt,
    String? failureReason,
    String? errorCode,
    StudioPrintAttemptOutcome outcome = StudioPrintAttemptOutcome.failed,
  }) async {
    var totalLoss = 0.0;
    var totalCost = 0.0;
    var alreadyRecorded = false;
    String? workspaceId;
    String? title;
    String? attemptId;
    final normalizedProgress = progressPercent?.clamp(0, 100);
    final lossFactor = (normalizedProgress ?? 0) / 100;
    final recordedOutcome = progressPercent == null
        ? StudioPrintAttemptOutcome.accountingReview
        : outcome;

    await transaction(() async {
      final row = await customSelect(
        'SELECT workspace_id, order_id, title, status '
        'FROM studio_work_orders WHERE id = ?',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (row == null) return;
      final currentStatus = StudioWorkOrderStatus.fromCode(
        row.read<String>('status'),
      );
      if (currentStatus == StudioWorkOrderStatus.completed ||
          currentStatus == StudioWorkOrderStatus.cancelled) {
        return;
      }
      workspaceId = row.read<String>('workspace_id');
      title = row.read<String>('title');
      final existingAttempt = await customSelect(
        'SELECT id, consumed_grams, material_cost FROM studio_print_attempts '
        'WHERE print_queue_id = ? AND attempt_no = ? LIMIT 1',
        variables: [Variable(printQueueId), Variable(attemptNo)],
      ).getSingleOrNull();
      if (existingAttempt != null) {
        attemptId = existingAttempt.read<String>('id');
        totalLoss = existingAttempt.read<double>('consumed_grams');
        totalCost = existingAttempt.read<double>('material_cost');
        alreadyRecorded = true;
        return;
      }
      attemptId = _uuid.v4();
      final materialRows = await customSelect(
        'SELECT * FROM studio_work_order_materials '
        'WHERE work_order_id = ? ORDER BY tool_index',
        variables: [Variable(id)],
      ).get();
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final materialRow in materialRows) {
        final material = _workOrderMaterial(materialRow);
        if (!material.isAllocated || material.consumableId == null) continue;
        final eventId = 'print-attempt-$attemptId-${material.id}';

        final loss = material.estimatedGrams * lossFactor;
        final costPerGram = await _farmMaterialCostPerGram(
          material.consumableId!,
        );
        totalLoss += loss;
        totalCost += loss * costPerGram;

        if (material.printerChannelId case final channelId?) {
          await customUpdate(
            'UPDATE printer_channels SET loaded_remaining_grams = '
            'MAX(0, loaded_remaining_grams - ?), updated_at = ? WHERE id = ?',
            variables: [
              Variable(loss),
              Variable(_driftNowSeconds()),
              Variable(channelId),
            ],
            updates: {db.printerChannels},
          );
        } else {
          await customUpdate(
            'UPDATE consumables SET remaining_grams = '
            'MAX(0, remaining_grams - ?), updated_at = ? WHERE id = ? '
            'AND ${_inventoryWhere(workspaceId!)}',
            variables: [
              Variable(loss),
              Variable(_driftNowSeconds()),
              Variable(material.consumableId),
              ..._inventoryVariables(workspaceId!),
            ],
            updates: {db.consumables},
          );
        }
        await customUpdate(
          'UPDATE studio_work_order_materials SET consumed_grams = '
          'consumed_grams + ?, updated_at = ? WHERE id = ?',
          variables: [Variable(loss), Variable(now), Variable(material.id)],
        );
        await customInsert(
          'INSERT INTO studio_inventory_events '
          '(id, workspace_id, consumable_id, event_type, delta_grams, reason, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(eventId),
            Variable(workspaceId),
            Variable(material.consumableId),
            Variable(StudioInventoryEventType.consume.name),
            Variable(-loss),
            Variable(
              '${title ?? '工单'} · '
              '${recordedOutcome == StudioPrintAttemptOutcome.accountingReview
                  ? '进度缺失，损耗待核对'
                  : outcome == StudioPrintAttemptOutcome.stopped
                  ? '打印中止'
                  : '打印失败'}'
              '${normalizedProgress == null ? '' : '损耗（进度 $normalizedProgress%）'}',
            ),
            Variable(now),
          ],
        );
      }

      await customInsert(
        'INSERT INTO studio_print_attempts '
        '(id, workspace_id, work_order_id, print_queue_id, attempt_no, '
        'printer_serial, outcome, progress_percent, consumed_grams, '
        'material_cost, failure_reason, error_code, started_at, ended_at, '
        'created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(attemptId),
          Variable(workspaceId),
          Variable(id),
          Variable(printQueueId),
          Variable(attemptNo),
          Variable(_nullable(printerSerial)),
          Variable(recordedOutcome.code),
          Variable(normalizedProgress),
          Variable(totalLoss),
          Variable(totalCost),
          Variable(_nullable(failureReason)),
          Variable(_nullable(errorCode)),
          Variable(startedAt?.millisecondsSinceEpoch),
          Variable(now),
          Variable(now),
          Variable(now),
        ],
      );

      await customUpdate(
        'UPDATE studio_work_orders SET status = ?, '
        'material_cost_snapshot = material_cost_snapshot + ?, updated_at = ? '
        'WHERE id = ?',
        variables: [
          Variable(StudioWorkOrderStatus.failed.name),
          Variable(totalCost),
          Variable(now),
          Variable(id),
        ],
      );
      await _reconcileOrderStatus(row.read<String>('order_id'));
    });

    if (workspaceId != null && !alreadyRecorded) {
      await recordActivity(
        workspaceId: workspaceId!,
        actionCode:
            recordedOutcome == StudioPrintAttemptOutcome.accountingReview
            ? 'work_order.accounting_review'
            : outcome == StudioPrintAttemptOutcome.stopped
            ? 'work_order.print_stopped'
            : 'work_order.print_failed',
        entityType: 'work_order',
        entityId: id,
        summary:
            '${title ?? '工单'}'
            '${recordedOutcome == StudioPrintAttemptOutcome.accountingReview
                ? '打印结果待核对'
                : outcome == StudioPrintAttemptOutcome.stopped
                ? '打印中止'
                : '打印失败'}'
            ' · 第 $attemptNo 次尝试 · ${normalizedProgress == null ? '未自动计损耗' : '已计损耗 ${totalLoss.toStringAsFixed(1)}g'}',
        notify: false,
      );
    }
    _emit();
    return totalLoss;
  }

  Future<void> recordCompletedWorkOrderAttempt({
    required String id,
    required int printQueueId,
    required int attemptNo,
    required String printerSerial,
    DateTime? startedAt,
    DateTime? endedAt,
    StudioPrintAttemptOutcome outcome = StudioPrintAttemptOutcome.completed,
    String? reason,
  }) async {
    final finishedAt = endedAt ?? DateTime.now();
    await transaction(() async {
      final existing = await customSelect(
        'SELECT 1 FROM studio_print_attempts '
        'WHERE print_queue_id = ? AND attempt_no = ? LIMIT 1',
        variables: [Variable(printQueueId), Variable(attemptNo)],
      ).getSingleOrNull();
      if (existing != null) return;
      final row = await customSelect(
        'SELECT workspace_id FROM studio_work_orders WHERE id = ?',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (row == null) return;
      var consumedGrams = 0.0;
      var materialCost = 0.0;
      if (outcome == StudioPrintAttemptOutcome.completed) {
        final materials = (await customSelect(
          'SELECT * FROM studio_work_order_materials WHERE work_order_id = ?',
          variables: [Variable(id)],
        ).get()).map(_workOrderMaterial);
        for (final material in materials) {
          consumedGrams += material.estimatedGrams;
          if (material.consumableId case final consumableId?) {
            materialCost +=
                material.estimatedGrams *
                await _farmMaterialCostPerGram(consumableId);
          }
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await customInsert(
        'INSERT INTO studio_print_attempts '
        '(id, workspace_id, work_order_id, print_queue_id, attempt_no, '
        'printer_serial, outcome, progress_percent, consumed_grams, '
        'material_cost, failure_reason, started_at, ended_at, created_at, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(_uuid.v4()),
          Variable(row.read<String>('workspace_id')),
          Variable(id),
          Variable(printQueueId),
          Variable(attemptNo),
          Variable(printerSerial),
          Variable(outcome.code),
          Variable(outcome == StudioPrintAttemptOutcome.completed ? 100 : null),
          Variable(consumedGrams),
          Variable(materialCost),
          Variable(_nullable(reason)),
          Variable(startedAt?.millisecondsSinceEpoch),
          Variable(finishedAt.millisecondsSinceEpoch),
          Variable(now),
          Variable(now),
        ],
      );
    });
    _emit();
  }

  /// A physical print must not remain "printing" merely because historical
  /// stock data cannot be settled. Completion is persisted and the attempt is
  /// flagged for a later inventory adjustment.
  Future<void> forceCompleteWorkOrderForAccountingReview(
    String id, {
    required String reason,
  }) async {
    String? workspaceId;
    await transaction(() async {
      final row = await customSelect(
        'SELECT workspace_id, order_id, quantity FROM studio_work_orders '
        'WHERE id = ?',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (row == null) return;
      workspaceId = row.read<String>('workspace_id');
      final now = DateTime.now().millisecondsSinceEpoch;
      await customUpdate(
        'UPDATE studio_work_order_materials SET reserved_grams = 0, '
        "status = CASE WHEN status = 'settled' THEN status ELSE 'released' END, "
        'updated_at = ? WHERE work_order_id = ?',
        variables: [Variable(now), Variable(id)],
      );
      await customUpdate(
        'UPDATE studio_work_orders SET completed_quantity = quantity, '
        "status = 'completed', updated_at = ? WHERE id = ?",
        variables: [Variable(now), Variable(id)],
      );
      await _reconcileOrderStatus(row.read<String>('order_id'));
    });
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId!,
        actionCode: 'work_order.accounting_review_required',
        entityType: 'work_order',
        entityId: id,
        summary: '打印已完成，耗材成本待核对：$reason',
        notify: false,
      );
    }
    _emit();
  }

  /// Reopens a technically completed print when the produced part fails
  /// inspection. The successful run remains charged; the next run gets a new
  /// queue attempt number and therefore adds its own material cost.
  Future<bool> rejectCompletedWorkOrderForQuality({
    required String id,
    int? printQueueId,
    int? attemptNo,
    String reason = '成品质检不合格',
  }) async {
    String? workspaceId;
    String? orderId;
    var allReserved = true;
    await transaction(() async {
      final row = await customSelect(
        'SELECT workspace_id, order_id, status FROM studio_work_orders '
        'WHERE id = ?',
        variables: [Variable(id)],
      ).getSingleOrNull();
      if (row == null) throw StateError('工单不存在');
      if (StudioWorkOrderStatus.fromCode(row.read<String>('status')) !=
          StudioWorkOrderStatus.completed) {
        throw StateError('只有已经打印完成的工单才能登记成品不合格');
      }
      workspaceId = row.read<String>('workspace_id');
      orderId = row.read<String>('order_id');
      QueryRow? attempt;
      if (printQueueId != null && attemptNo != null) {
        attempt = await customSelect(
          'SELECT * FROM studio_print_attempts '
          'WHERE print_queue_id = ? AND attempt_no = ? LIMIT 1',
          variables: [Variable(printQueueId), Variable(attemptNo)],
        ).getSingleOrNull();
      }
      attempt ??= await customSelect(
        'SELECT * FROM studio_print_attempts WHERE work_order_id = ? '
        "AND outcome = 'completed' ORDER BY ended_at DESC LIMIT 1",
        variables: [Variable(id)],
      ).getSingleOrNull();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (attempt != null) {
        await customUpdate(
          "UPDATE studio_print_attempts SET outcome = 'quality_rejected', "
          'failure_reason = ?, updated_at = ? WHERE id = ?',
          variables: [
            Variable(reason),
            Variable(now),
            Variable(attempt.read<String>('id')),
          ],
        );
      } else {
        final count = await customSelect(
          'SELECT COUNT(*) AS value FROM studio_print_attempts '
          'WHERE work_order_id = ?',
          variables: [Variable(id)],
        ).getSingle();
        await customInsert(
          'INSERT INTO studio_print_attempts '
          '(id, workspace_id, work_order_id, print_queue_id, attempt_no, '
          "outcome, progress_percent, consumed_grams, material_cost, "
          'failure_reason, ended_at, created_at, updated_at) '
          "VALUES (?, ?, ?, ?, ?, 'quality_rejected', 100, 0, 0, ?, ?, ?, ?)",
          variables: [
            Variable(_uuid.v4()),
            Variable(workspaceId),
            Variable(id),
            Variable(printQueueId),
            Variable(attemptNo ?? count.read<int>('value') + 1),
            Variable(reason),
            Variable(now),
            Variable(now),
            Variable(now),
          ],
        );
      }

      final materials = (await customSelect(
        'SELECT * FROM studio_work_order_materials WHERE work_order_id = ?',
        variables: [Variable(id)],
      ).get()).map(_workOrderMaterial).toList();
      for (final material in materials) {
        var canReserve = material.consumableId != null;
        if (canReserve && material.printerChannelId != null) {
          final channelId = material.printerChannelId!;
          canReserve =
              await getPrinterChannelAvailableGrams(
                    channelId,
                    excludingWorkOrderId: id,
                  ) +
                  .0001 >=
              material.estimatedGrams;
        } else if (canReserve && material.consumableId != null) {
          final consumableId = material.consumableId!;
          final available = await _getConsumableAvailability(
            consumableId,
            workspaceId: workspaceId!,
            excludingWorkOrderId: id,
          );
          canReserve =
              available.availableGrams + .0001 >= material.estimatedGrams;
        }
        allReserved = allReserved && canReserve;
        await customUpdate(
          'UPDATE studio_work_order_materials SET reserved_grams = ?, '
          'status = ?, settled_at = NULL, updated_at = ? WHERE id = ?',
          variables: [
            Variable(canReserve ? material.estimatedGrams : 0),
            Variable(
              canReserve
                  ? StudioWorkOrderMaterialStatus.reserved.name
                  : StudioWorkOrderMaterialStatus.released.name,
            ),
            Variable(now),
            Variable(material.id),
          ],
        );
      }
      await customUpdate(
        'UPDATE studio_work_orders SET completed_quantity = 0, '
        "status = 'failed', updated_at = ? WHERE id = ?",
        variables: [Variable(now), Variable(id)],
      );
      await customUpdate(
        "UPDATE studio_orders SET status = 'production', updated_at = ? "
        'WHERE id = ?',
        variables: [Variable(now), Variable(orderId)],
      );
    });
    await recordActivity(
      workspaceId: workspaceId!,
      actionCode: 'work_order.quality_rejected',
      entityType: 'work_order',
      entityId: id,
      summary: '$reason · 已保留本次成本并重新开放生产',
      notify: false,
    );
    _emit();
    return allReserved;
  }

  /// Verifies that the currently allocated roll still has enough material for
  /// a complete retry after the failed attempt has been charged as waste.
  Future<void> validateWorkOrderRetry(String id) async {
    final row = await customSelect(
      'SELECT workspace_id, printer_id, status FROM studio_work_orders '
      'WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (row == null) throw StateError('工单不存在');
    final status = StudioWorkOrderStatus.fromCode(row.read<String>('status'));
    if (status == StudioWorkOrderStatus.completed ||
        status == StudioWorkOrderStatus.cancelled) {
      throw StateError('已结束的工单不能重试');
    }
    final workspaceId = row.read<String>('workspace_id');
    final materials = (await customSelect(
      'SELECT * FROM studio_work_order_materials '
      'WHERE work_order_id = ? ORDER BY tool_index',
      variables: [Variable(id)],
    ).get()).map(_workOrderMaterial).toList();
    if (materials.any((item) => !item.isAllocated)) {
      throw StateError('请先为失败工单重新分配每个耗材通道');
    }

    final demandByConsumable = <int, double>{};
    final demandByChannel = <int, double>{};
    for (final material in materials) {
      if (material.printerChannelId case final channelId?) {
        final channel = await customSelect(
          'SELECT printer_id, consumable_id, farm_roll_paused '
          'FROM printer_channels WHERE id = ?',
          variables: [Variable(channelId)],
        ).getSingleOrNull();
        if (channel == null ||
            channel.read<int?>('printer_id') != row.read<int?>('printer_id') ||
            channel.read<int?>('consumable_id') != material.consumableId) {
          throw StateError('失败工单原来的耗材槽位已经变化，请重新分配耗材');
        }
        if (channel.read<int>('farm_roll_paused') > 0) {
          throw StateError('失败工单使用的耗材卷正在维修暂存，请恢复或换卷后重试');
        }
        demandByChannel.update(
          channelId,
          (value) => value + material.estimatedGrams,
          ifAbsent: () => material.estimatedGrams,
        );
      } else if (material.consumableId case final consumableId?) {
        demandByConsumable.update(
          consumableId,
          (value) => value + material.estimatedGrams,
          ifAbsent: () => material.estimatedGrams,
        );
      }
    }
    for (final demand in demandByChannel.entries) {
      final available = await getPrinterChannelAvailableGrams(
        demand.key,
        excludingWorkOrderId: id,
      );
      if (available + 0.0001 < demand.value) {
        throw StateError(
          '失败后槽位只剩 ${available.toStringAsFixed(1)}g，完整重打需要 '
          '${demand.value.toStringAsFixed(1)}g，请换卷后重试',
        );
      }
    }
    for (final demand in demandByConsumable.entries) {
      final available = await _getConsumableAvailability(
        demand.key,
        workspaceId: workspaceId,
        excludingWorkOrderId: id,
      );
      if (available.availableGrams + 0.0001 < demand.value) {
        throw StateError(
          '失败后库存只剩 ${available.availableGrams.toStringAsFixed(1)}g，'
          '完整重打需要 ${demand.value.toStringAsFixed(1)}g，请换卷后重试',
        );
      }
    }
  }

  Future<void> updateProductionPlateSlice({
    required String id,
    required StudioPlateSliceStatus status,
    String? artifactPath,
    String? artifactSha256,
    int estimatedSeconds = 0,
    double estimatedGrams = 0,
    int totalLayers = 0,
    int toolChangeCount = 0,
    List<StudioPlateFilamentUsage> filaments = const [],
    String? targetModel,
    double? nozzleDiameter,
    bool autoEjectEnabled = false,
    List<int>? thumbnailBytes,
  }) async {
    final activityRow = await customSelect(
      'SELECT workspace_id, name FROM studio_production_plates WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      if (status == StudioPlateSliceStatus.slicing ||
          status == StudioPlateSliceStatus.sliced) {
        final active = await customSelect(
          'SELECT COUNT(*) AS count FROM studio_work_orders '
          'WHERE production_plate_id = ? AND printer_id IS NOT NULL '
          "AND status != 'cancelled'",
          variables: [Variable(id)],
        ).getSingle();
        if (active.read<int>('count') > 0) {
          throw StateError('该盘已有排产或生产记录，请先撤回未开始的排产；已开工任务不能覆盖切片');
        }
      }
      if (status == StudioPlateSliceStatus.sliced) {
        final settled = await customSelect(
          'SELECT COUNT(*) AS count FROM studio_work_order_materials '
          "WHERE production_plate_id = ? AND status = 'settled'",
          variables: [Variable(id)],
        ).getSingle();
        if (settled.read<int>('count') > 0) {
          throw StateError('该盘已有工单完成耗材结算，不能用重切片覆盖历史用量');
        }
        await customUpdate(
          'UPDATE studio_production_plates SET slice_status = ?, '
          'slice_artifact_path = ?, slice_artifact_sha256 = ?, '
          'slice_target_model = ?, slice_nozzle_diameter = ?, '
          'auto_eject_enabled = ?, '
          'thumbnail_base64 = COALESCE(?, thumbnail_base64), '
          'estimated_seconds = ?, estimated_grams = ?, total_layers = ?, '
          'tool_change_count = ?, filament_usage_json = ?, updated_at = ? WHERE id = ?',
          variables: [
            Variable(status.name),
            Variable(_nullable(artifactPath)),
            Variable(_nullable(artifactSha256)),
            Variable(_nullable(targetModel)),
            Variable(nozzleDiameter),
            Variable(autoEjectEnabled ? 1 : 0),
            Variable(
              thumbnailBytes == null ? null : base64Encode(thumbnailBytes),
            ),
            Variable(math.max(0, estimatedSeconds)),
            Variable(math.max(0, estimatedGrams)),
            Variable(math.max(0, totalLayers)),
            Variable(math.max(0, toolChangeCount)),
            Variable(_encodeFilaments(filaments)),
            Variable(now),
            Variable(id),
          ],
        );
        await customUpdate(
          'UPDATE studio_work_orders SET estimated_seconds = ? * quantity, '
          "status = CASE WHEN status = 'paused' THEN 'queued' ELSE status END, "
          'updated_at = ? WHERE production_plate_id = ?',
          variables: [
            Variable(math.max(0, estimatedSeconds)),
            Variable(now),
            Variable(id),
          ],
        );
        await _refreshPlateMaterialRequirements(
          productionPlateId: id,
          estimatedGrams: estimatedGrams,
          filaments: filaments,
          now: now,
        );
      } else {
        await customUpdate(
          'UPDATE studio_production_plates SET slice_status = ?, updated_at = ? WHERE id = ?',
          variables: [Variable(status.name), Variable(now), Variable(id)],
        );
      }
    });
    if (activityRow != null) {
      await recordActivity(
        workspaceId: activityRow.read<String>('workspace_id'),
        actionCode: 'plate.slice_updated',
        entityType: 'plate',
        entityId: id,
        summary: '${activityRow.read<String>('name')}：切片状态 ${status.name}',
        notify: false,
      );
    }
    _emit();
  }

  /// Reconciles a personal project's source 3MF after it was saved by the
  /// native Bambu Studio editor. The source file remains the single source of
  /// truth; stale thumbnails and stale slice metadata are replaced together
  /// so the next print cannot silently reuse an older toolpath.
  ///
  /// Returns the number of existing plates that were refreshed. New plate
  /// indexes are intentionally not inserted here because their order items
  /// and work-order quantities require an explicit project import decision.
  Future<int> syncProductionPackageFromInspection({
    required String packageId,
    required String localPath,
    required ProductionPackageInspection inspection,
    String? sourceName,
  }) async {
    final packageRow = await customSelect(
      'SELECT * FROM studio_production_packages WHERE id = ?',
      variables: [Variable(packageId)],
    ).getSingleOrNull();
    if (packageRow == null) throw StateError('生产项目不存在');

    final plateRows = await customSelect(
      'SELECT id, plate_index, name FROM studio_production_plates '
      'WHERE package_id = ?',
      variables: [Variable(packageId)],
    ).get();
    final inspectedByIndex = <int, ProductionPlateInspection>{
      for (final plate in inspection.productionPlates) plate.plateIndex: plate,
    };
    final normalizedPath = File(localPath).absolute.path;
    final nextSourceName = sourceName?.trim();
    final name = nextSourceName == null || nextSourceName.isEmpty
        ? packageRow.read<String>('source_name')
        : nextSourceName;
    final now = DateTime.now().millisecondsSinceEpoch;
    var refreshed = 0;

    await transaction(() async {
      await customUpdate(
        'UPDATE studio_production_packages SET source_name = ?, '
        'local_path = ?, artifact_sha256 = ?, artifact_kind = ?, '
        'slicer_name = ?, slicer_version = ?, target_model = ?, '
        'nozzle_diameter = ? WHERE id = ?',
        variables: [
          Variable(name),
          Variable(normalizedPath),
          Variable(_nullable(inspection.artifactSha256)),
          Variable(inspection.kind.name),
          Variable(_nullable(inspection.slicerName)),
          Variable(_nullable(inspection.slicerVersion)),
          Variable(_nullable(inspection.targetModel)),
          Variable(inspection.nozzleDiameter),
          Variable(packageId),
        ],
      );

      for (final row in plateRows) {
        final plate = inspectedByIndex[row.read<int>('plate_index')];
        if (plate == null) continue;
        final hasToolpath = plate.hasToolpath;
        final plateName = plate.name.trim().isEmpty
            ? row.read<String>('name')
            : plate.name.trim();
        final filaments = [
          for (final item in plate.filaments)
            StudioPlateFilamentUsage(
              toolIndex: item.toolIndex,
              grams: item.grams,
              vendor: item.vendor,
              materialType: item.materialType,
              colorHex: item.colorHex,
              trayId: item.trayId,
              sku: item.sku,
              usedForObject: item.usedForObject,
              usedForSupport: item.usedForSupport,
              groupId: item.groupId,
              nozzleDiameter: item.nozzleDiameter,
              volumeType: item.volumeType,
            ),
        ];
        await customUpdate(
          'UPDATE studio_production_plates SET name = ?, '
          'estimated_seconds = ?, estimated_grams = ?, slice_status = ?, '
          'slice_artifact_path = ?, slice_artifact_sha256 = ?, '
          'slice_target_model = ?, slice_nozzle_diameter = ?, '
          'auto_eject_enabled = NULL, thumbnail_base64 = ?, '
          'total_layers = ?, tool_change_count = ?, filament_usage_json = ?, '
          'updated_at = ? WHERE id = ?',
          variables: [
            Variable(plateName),
            Variable(math.max(0, plate.estimatedSeconds)),
            Variable(math.max(0, plate.estimatedGrams)),
            Variable(
              hasToolpath
                  ? StudioPlateSliceStatus.sliced.name
                  : StudioPlateSliceStatus.pending.name,
            ),
            Variable(hasToolpath ? normalizedPath : null),
            Variable(hasToolpath ? _nullable(inspection.artifactSha256) : null),
            Variable(hasToolpath ? _nullable(inspection.targetModel) : null),
            Variable(hasToolpath ? inspection.nozzleDiameter : null),
            Variable(
              plate.thumbnailBytes == null
                  ? null
                  : base64Encode(plate.thumbnailBytes!),
            ),
            Variable(math.max(0, plate.totalLayers)),
            Variable(math.max(0, plate.toolChangeCount)),
            Variable(_encodeFilaments(filaments)),
            Variable(now),
            Variable(row.read<String>('id')),
          ],
        );

        // Bambu may add/remove objects while arranging. Rebuild the small
        // personal object list so visible contents and print quantities follow
        // the saved 3MF instead of retaining stale import metadata.
        await customUpdate(
          'DELETE FROM studio_order_items WHERE plate_id = ?',
          variables: [Variable(row.read<String>('id'))],
        );
        for (final part in plate.parts) {
          await customInsert(
            'INSERT INTO studio_order_items '
            '(id, workspace_id, order_id, package_id, plate_id, source_key, '
            'name, per_run_quantity, required_quantity, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            variables: [
              Variable(_uuid.v4()),
              Variable(packageRow.read<String>('workspace_id')),
              Variable(packageRow.read<String>('order_id')),
              Variable(packageId),
              Variable(row.read<String>('id')),
              Variable(part.key),
              Variable(part.name.trim().isEmpty ? '未命名模型' : part.name.trim()),
              Variable(math.max(1, part.instancesPerRun)),
              Variable(math.max(1, part.instancesPerRun)),
              Variable(now),
            ],
          );
        }

        final workOrderSeconds = hasToolpath
            ? math.max(0, plate.estimatedSeconds)
            : 0;
        await customUpdate(
          'UPDATE studio_work_orders SET status = CASE '
          "WHEN ? = 1 AND status = 'paused' THEN 'queued' "
          "WHEN ? = 0 AND status IN ('queued', 'assigned') THEN 'paused' "
          'ELSE status END, estimated_seconds = ? * quantity, updated_at = ? '
          'WHERE production_plate_id = ? AND status != \'cancelled\'',
          variables: [
            Variable(hasToolpath ? 1 : 0),
            Variable(hasToolpath ? 1 : 0),
            Variable(workOrderSeconds),
            Variable(now),
            Variable(row.read<String>('id')),
          ],
        );
        await _refreshPlateMaterialRequirements(
          productionPlateId: row.read<String>('id'),
          estimatedGrams: plate.estimatedGrams,
          filaments: filaments,
          now: now,
        );
        refreshed++;
      }
    });
    _emit();
    return refreshed;
  }

  /// Available stock after all three task systems have made their promises.
  Future<StudioConsumableAvailability> getConsumableAvailability(
    int consumableId, {
    required String workspaceId,
    String? excludingWorkOrderId,
  }) => _getConsumableAvailability(
    consumableId,
    workspaceId: workspaceId,
    excludingWorkOrderId: excludingWorkOrderId,
  );

  Future<void> reserveWorkOrderMaterials({
    required String workOrderId,
    required Map<int, int> consumableByTool,
    Map<int, int>? printerChannelByTool,
    bool notify = true,
  }) async {
    String? activityWorkspaceId;
    await transaction(() async {
      final workOrder = await customSelect(
        'SELECT status, workspace_id, printer_id FROM studio_work_orders WHERE id = ?',
        variables: [Variable(workOrderId)],
      ).getSingleOrNull();
      if (workOrder == null) throw StateError('工单不存在');
      final workspaceId = workOrder.read<String>('workspace_id');
      activityWorkspaceId = workspaceId;
      final status = StudioWorkOrderStatus.fromCode(
        workOrder.read<String>('status'),
      );
      if (status == StudioWorkOrderStatus.completed ||
          status == StudioWorkOrderStatus.cancelled) {
        throw StateError('已结束的工单不能重新分配耗材');
      }

      final rows = await customSelect(
        'SELECT * FROM studio_work_order_materials '
        'WHERE work_order_id = ? ORDER BY tool_index',
        variables: [Variable(workOrderId)],
      ).get();
      final materials = rows.map(_workOrderMaterial).toList();
      if (materials.isEmpty) throw StateError('该工单还没有可分配的切片耗材需求');
      if (materials.any((item) => item.isSettled)) {
        throw StateError('该工单已经完成耗材结算');
      }
      if (consumableByTool.length != materials.length ||
          materials.any(
            (item) => !consumableByTool.containsKey(item.toolIndex),
          )) {
        throw StateError('必须为每个有效工具通道选择一卷耗材');
      }

      final demandByConsumable = <int, double>{};
      final demandByChannel = <int, double>{};
      for (final material in materials) {
        final consumableId = consumableByTool[material.toolIndex]!;
        final consumable = await customSelect(
          'SELECT material_type, color_hex FROM consumables WHERE id = ? '
          'AND ${_inventoryWhere(workspaceId)}',
          variables: [
            Variable(consumableId),
            ..._inventoryVariables(workspaceId),
          ],
        ).getSingleOrNull();
        if (consumable == null) throw StateError('耗材卷 #$consumableId 不存在');
        final requiredType = material.materialType?.trim();
        final actualType = consumable.read<String>('material_type').trim();
        if (requiredType?.isNotEmpty == true &&
            requiredType!.toUpperCase() != actualType.toUpperCase()) {
          throw StateError(
            '通道 ${material.toolIndex + 1} 需要 $requiredType，不能分配 $actualType',
          );
        }
        final requiredColor = _normalizedColor(material.colorHex);
        final actualColor = _normalizedColor(
          consumable.read<String>('color_hex'),
        );
        if (requiredColor != null && requiredColor != actualColor) {
          throw StateError('通道 ${material.toolIndex + 1} 的耗材颜色与切片不一致');
        }
        int? selectedChannelId;
        if (printerChannelByTool != null) {
          final channelId = printerChannelByTool[material.toolIndex];
          if (channelId == null) throw StateError('必须为每个工具选择具体 AMS/外挂槽位');
          selectedChannelId = channelId;
          final channel = await customSelect(
            'SELECT printer_id, consumable_id, loaded_remaining_grams, '
            'farm_roll_paused '
            'FROM printer_channels WHERE id = ?',
            variables: [Variable(channelId)],
          ).getSingleOrNull();
          if (channel == null ||
              channel.read<int?>('consumable_id') != consumableId ||
              channel.read<int>('printer_id') !=
                  workOrder.read<int?>('printer_id')) {
            throw StateError('所选槽位不属于该工单打印机，或槽内耗材已变化');
          }
          if (channel.read<int>('farm_roll_paused') > 0) {
            throw StateError('所选槽位的耗材正在维修暂存，不能排产');
          }
          if (_usesFarmInventory &&
              channel.read<double>('loaded_remaining_grams') <=
                  minimumReusableSpoolGrams) {
            throw StateError('所选槽位余量必须大于 30g 才能继续排产');
          }
          demandByChannel.update(
            channelId,
            (value) => value + material.estimatedGrams,
            ifAbsent: () => material.estimatedGrams,
          );
        }
        if (selectedChannelId == null) {
          // Compatibility path for legacy/manual work orders that predate
          // printer-slot assignment. Normal farm dispatch always uses a slot;
          // once loaded, its roll balance is independent from warehouse stock.
          demandByConsumable.update(
            consumableId,
            (value) => value + material.estimatedGrams,
            ifAbsent: () => material.estimatedGrams,
          );
        }
      }

      for (final demand in demandByConsumable.entries) {
        final available = await _getConsumableAvailability(
          demand.key,
          workspaceId: workspaceId,
          excludingWorkOrderId: workOrderId,
        );
        if (available.availableGrams + 0.0001 < demand.value) {
          throw StateError(
            '耗材卷 #${demand.key} 可用 ${available.availableGrams.toStringAsFixed(1)} g，'
            '本工单需要 ${demand.value.toStringAsFixed(1)} g',
          );
        }
      }
      for (final demand in demandByChannel.entries) {
        final available = await getPrinterChannelAvailableGrams(
          demand.key,
          excludingWorkOrderId: workOrderId,
        );
        if (available + 0.0001 < demand.value) {
          throw StateError(
            '所选槽位扣除其他排队任务后只剩 ${available.toStringAsFixed(1)} g，'
            '本工单需要 ${demand.value.toStringAsFixed(1)} g',
          );
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final material in materials) {
        await customUpdate(
          'UPDATE studio_work_order_materials SET consumable_id = ?, printer_channel_id = ?, '
          "reserved_grams = estimated_grams, status = 'reserved', updated_at = ? "
          'WHERE id = ?',
          variables: [
            Variable(consumableByTool[material.toolIndex]),
            Variable(printerChannelByTool?[material.toolIndex]),
            Variable(now),
            Variable(material.id),
          ],
        );
      }
    });
    if (activityWorkspaceId != null) {
      await recordActivity(
        workspaceId: activityWorkspaceId!,
        actionCode: 'work_order.materials_reserved',
        entityType: 'work_order',
        entityId: workOrderId,
        summary: '配置并核验打印耗材',
        notify: false,
      );
    }
    if (notify) _emit();
  }

  Future<double> getPrinterChannelAvailableGrams(
    int channelId, {
    String? excludingWorkOrderId,
  }) async {
    final row = await customSelect(
      'SELECT loaded_remaining_grams, farm_roll_paused '
      'FROM printer_channels WHERE id = ?',
      variables: [Variable(channelId)],
    ).getSingleOrNull();
    if ((row?.read<int>('farm_roll_paused') ?? 0) > 0) return 0;
    final remaining = row?.read<double>('loaded_remaining_grams') ?? 0;
    final reserved = await customSelect(
      'SELECT COALESCE(SUM(reserved_grams), 0) AS value '
      'FROM studio_work_order_materials WHERE printer_channel_id = ? '
      "AND status = 'reserved' "
      '${excludingWorkOrderId == null ? '' : 'AND work_order_id != ?'}',
      variables: [
        Variable(channelId),
        if (excludingWorkOrderId != null) Variable(excludingWorkOrderId),
      ],
    ).getSingle();
    return math.max(0, remaining - reserved.read<double>('value'));
  }

  Future<void> releaseWorkOrderMaterials(String workOrderId) async {
    final workspaceId = await _workspaceIdFor(
      'studio_work_orders',
      workOrderId,
    );
    await customUpdate(
      'UPDATE studio_work_order_materials SET reserved_grams = 0, '
      "status = 'released', updated_at = ? "
      "WHERE work_order_id = ? AND status IN ('unallocated', 'reserved')",
      variables: [
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(workOrderId),
      ],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'work_order.materials_released',
        entityType: 'work_order',
        entityId: workOrderId,
        summary: '释放工单耗材预留',
        notify: false,
      );
    }
    _emit();
  }

  Future<String> addQuote(StudioQuote quote) async {
    await _insertQuoteRow(quote);
    await recordActivity(
      workspaceId: quote.workspaceId,
      actionCode: 'quote.created',
      entityType: 'quote',
      entityId: quote.id,
      summary: '创建报价 ${quote.quoteNo}',
      notify: false,
    );
    _emit();
    return quote.id;
  }

  Future<void> _insertQuoteRow(
    StudioQuote quote, {
    String? orderIdOverride,
  }) async {
    await customInsert(
      'INSERT INTO studio_quotes '
      '(id, workspace_id, customer_id, order_id, cost_config_id, quote_no, title, status, material_label, '
      'estimated_grams, material_cost_per_kg_snapshot, machine_hours, machine_rate_per_hour, '
      'labor_hours, labor_rate_per_hour, electricity_cost, packaging_cost, risk_percent, '
      'markup_percent, total_cost, quoted_price, note, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable(quote.id),
        Variable(quote.workspaceId),
        Variable(_nullable(quote.customerId)),
        Variable(_nullable(orderIdOverride ?? quote.orderId)),
        Variable(quote.costConfigId),
        Variable(quote.quoteNo),
        Variable(quote.title),
        Variable(quote.status.name),
        Variable(quote.materialLabel),
        Variable(quote.estimatedGrams),
        Variable(quote.materialCostPerKgSnapshot),
        Variable(quote.machineHours),
        Variable(quote.machineRatePerHour),
        Variable(quote.laborHours),
        Variable(quote.laborRatePerHour),
        Variable(quote.electricityCost),
        Variable(quote.packagingCost),
        Variable(quote.riskPercent),
        Variable(quote.markupPercent),
        Variable(quote.totalCost),
        Variable(quote.quotedPrice),
        Variable(_nullable(quote.note)),
        Variable(quote.createdAt.millisecondsSinceEpoch),
        Variable(quote.updatedAt.millisecondsSinceEpoch),
      ],
    );
  }

  Future<void> updateQuoteStatus(String id, StudioQuoteStatus status) async {
    final workspaceId = await _workspaceIdFor('studio_quotes', id);
    await customUpdate(
      'UPDATE studio_quotes SET status = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable(status.name),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(id),
      ],
    );
    if (workspaceId != null) {
      await recordActivity(
        workspaceId: workspaceId,
        actionCode: 'quote.status_updated',
        entityType: 'quote',
        entityId: id,
        summary: '更新报价状态为 ${status.name}',
        notify: false,
      );
    }
    _emit();
  }

  Future<double> adjustInventory({
    required String workspaceId,
    required int consumableId,
    required double deltaGrams,
    required StudioInventoryEventType type,
    required String reason,
    String? memberId,
  }) async {
    final actualDelta = await transaction(() async {
      final row = await customSelect(
        'SELECT total_grams, remaining_grams FROM consumables WHERE id = ? '
        "AND inventory_scope = 'farm' AND farm_workspace_id = ?",
        variables: [Variable(consumableId), Variable(workspaceId)],
      ).getSingleOrNull();
      if (row == null) {
        throw StateError('耗材卷 #$consumableId 不属于当前农场库存');
      }
      final current = row.read<double>('remaining_grams');
      final next = math.max(0.0, current + deltaGrams);
      final nextTotal = math.max(row.read<double>('total_grams'), next);
      if (deltaGrams < 0) {
        Future<double> reserved(String sql) async {
          final value = await customSelect(
            sql,
            variables: [Variable(consumableId)],
          ).getSingle();
          return (value.data.values.first as num?)?.toDouble() ?? 0;
        }

        final protectedGrams =
            await reserved(
              'SELECT COALESCE(SUM(reserved_grams), 0) FROM spool_reservations '
              "WHERE consumable_id = ? AND status = 'active'",
            ) +
            await reserved(
              'SELECT COALESCE(SUM(CASE WHEN estimated_grams > last_deducted_grams '
              'THEN estimated_grams - last_deducted_grams ELSE 0 END), 0) '
              'FROM print_task_consumables WHERE consumable_id = ? '
              'AND consumed_at IS NULL',
            ) +
            await reserved(
              'SELECT COALESCE(SUM(reserved_grams), 0) '
              'FROM studio_work_order_materials WHERE consumable_id = ? '
              "AND status = 'reserved' AND printer_channel_id IS NULL",
            );
        if (next + 0.0001 < protectedGrams) {
          throw StateError(
            '调整后库存将低于已预留的 ${protectedGrams.toStringAsFixed(1)}g，请先释放相关任务',
          );
        }
      }
      final actual = next - current;
      await customUpdate(
        'UPDATE consumables SET total_grams = ?, remaining_grams = ?, '
        'updated_at = ? WHERE id = ? '
        "AND inventory_scope = 'farm' AND farm_workspace_id = ?",
        variables: [
          Variable(nextTotal),
          Variable(next),
          Variable(_driftNowSeconds()),
          Variable(consumableId),
          Variable(workspaceId),
        ],
        updates: {db.consumables},
      );
      await customInsert(
        'INSERT INTO studio_inventory_events '
        '(id, workspace_id, consumable_id, event_type, delta_grams, reason, member_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(_uuid.v4()),
          Variable(workspaceId),
          Variable(consumableId),
          Variable(type.name),
          Variable(actual),
          Variable(reason.trim()),
          Variable(_nullable(memberId)),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
      return actual;
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'inventory.adjusted',
      entityType: 'consumable',
      entityId: '$consumableId',
      summary:
          '${reason.trim()} · ${actualDelta >= 0 ? '+' : ''}${actualDelta.toStringAsFixed(1)}g',
      notify: false,
    );
    _emit();
    return actualDelta;
  }

  Future<String> receiveInventoryBatch({
    required String workspaceId,
    required String batchNo,
    required DateTime receivedAt,
    required List<StudioBatchReceiveLine> lines,
    String? supplier,
    String? note,
    String? memberId,
  }) async {
    final normalizedBatchNo = batchNo.trim();
    if (normalizedBatchNo.isEmpty) {
      throw ArgumentError.value(batchNo, 'batchNo', '批次号不能为空');
    }
    if (lines.isEmpty) {
      throw ArgumentError.value(lines, 'lines', '至少需要一条入库明细');
    }
    for (final line in lines) {
      if (line.manufacturer.trim().isEmpty ||
          line.materialType.trim().isEmpty ||
          !RegExp(
            r'^#[0-9A-F]{6}$',
          ).hasMatch(line.colorHex.trim().toUpperCase()) ||
          !const {
            'solid',
            'multi',
            'gradient',
          }.contains(line.colorMode.trim().toLowerCase()) ||
          (line.colorMode.trim().toLowerCase() != 'solid' &&
              !RegExp(
                r'^#[0-9A-F]{6}$',
              ).hasMatch(line.secondaryColorHex?.trim().toUpperCase() ?? '')) ||
          line.rolls <= 0 ||
          line.rolls > 500 ||
          !line.gramsPerRoll.isFinite ||
          line.gramsPerRoll != _farmRollGrams) {
        throw ArgumentError('每条明细需包含厂商、材质和 1-500 卷；农场库存每卷固定 1000g');
      }
    }

    final groupedLines = <String, StudioBatchReceiveLine>{};
    for (final line in lines) {
      final key = [
        (line.brandCode ?? line.manufacturer).trim().toLowerCase(),
        (line.model ?? line.materialType).trim().toLowerCase(),
        line.materialType.trim().toLowerCase(),
        line.colorHex.trim().toUpperCase(),
        line.colorMode.trim().toLowerCase(),
        line.secondaryColorHex?.trim().toUpperCase() ?? '',
        line.unitCost.toStringAsFixed(3),
      ].join('|');
      final existing = groupedLines[key];
      groupedLines[key] = existing == null
          ? line
          : StudioBatchReceiveLine(
              manufacturer: existing.manufacturer,
              brandCode: existing.brandCode,
              model: existing.model,
              materialType: existing.materialType,
              colorHex: existing.colorHex,
              colorName: existing.colorName,
              colorMode: existing.colorMode,
              secondaryColorHex: existing.secondaryColorHex,
              rolls: existing.rolls + line.rolls,
              gramsPerRoll: _farmRollGrams,
              unitCost: existing.unitCost,
            );
    }
    final normalizedLines = groupedLines.values.toList(growable: false);

    final batchId = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final driftNow = _normalizeDriftEpochSeconds(now);
    final rollCount = normalizedLines.fold<int>(
      0,
      (sum, line) => sum + line.rolls,
    );
    final totalGrams = normalizedLines.fold<double>(
      0,
      (sum, line) => sum + line.rolls * _farmRollGrams,
    );
    await transaction(() async {
      await customInsert(
        'INSERT INTO studio_inventory_batches '
        '(id, workspace_id, batch_no, supplier, received_at, roll_count, total_grams, note, member_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(batchId),
          Variable(workspaceId),
          Variable(normalizedBatchNo),
          Variable(_nullable(supplier)),
          Variable(receivedAt.millisecondsSinceEpoch),
          Variable(rollCount),
          Variable(totalGrams),
          Variable(_nullable(note)),
          Variable(_nullable(memberId)),
          Variable(now),
          Variable(now),
        ],
      );
      for (final line in normalizedLines) {
        final manufacturer = line.manufacturer.trim();
        final material = line.materialType.trim();
        final model = line.model?.trim().isNotEmpty == true
            ? line.model!.trim()
            : material;
        final colorHex = line.colorHex.trim().toUpperCase();
        final lineTotalGrams = line.rolls * _farmRollGrams;
        final consumableId = await customInsert(
          'INSERT INTO consumables '
          '(uid, manufacturer, model, material_type, color_hex, color_name, '
          'total_grams, remaining_grams, batch_no, purchase_date, note, '
          'created_at, updated_at, inventory_scope, farm_workspace_id, '
          'brand_code, color_mode, secondary_color_hex, archived) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(_uuid.v4()),
            Variable(manufacturer),
            Variable(model),
            Variable(material),
            Variable(colorHex),
            Variable(_nullable(line.colorName)),
            Variable(lineTotalGrams),
            Variable(lineTotalGrams),
            Variable(normalizedBatchNo),
            Variable(_driftDateSeconds(receivedAt)),
            Variable(_nullable(note)),
            Variable(driftNow),
            Variable(driftNow),
            const Variable('farm'),
            Variable(workspaceId),
            Variable(_nullable(line.brandCode)),
            Variable(line.colorMode),
            Variable(_nullable(line.secondaryColorHex)),
            const Variable(0),
          ],
          updates: {db.consumables},
        );
        await customInsert(
          'INSERT INTO studio_inventory_batch_items '
          '(id, batch_id, consumable_id, roll_count, grams_per_roll, unit_cost, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(_uuid.v4()),
            Variable(batchId),
            Variable(consumableId),
            Variable(line.rolls),
            const Variable(_farmRollGrams),
            Variable(math.max(0, line.unitCost)),
            Variable(now),
            Variable(now),
          ],
        );
        await customInsert(
          'INSERT INTO studio_inventory_events '
          '(id, workspace_id, consumable_id, event_type, delta_grams, reason, member_id, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(_uuid.v4()),
            Variable(workspaceId),
            Variable(consumableId),
            Variable(StudioInventoryEventType.receive.name),
            Variable(lineTotalGrams),
            Variable('批量入库 $normalizedBatchNo（${line.rolls} 卷）'),
            Variable(_nullable(memberId)),
            Variable(now),
          ],
        );
      }
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'inventory.batch_received',
      entityType: 'inventory_batch',
      entityId: batchId,
      summary: '批次 $normalizedBatchNo 入库 · $rollCount 卷',
      notify: false,
    );
    _emit();
    return batchId;
  }

  Future<void> updateInventoryBatch({
    required String id,
    required String workspaceId,
    required String batchNo,
    required DateTime receivedAt,
    String? supplier,
    String? note,
    String? memberId,
  }) async {
    final normalizedBatchNo = batchNo.trim();
    if (normalizedBatchNo.isEmpty) {
      throw ArgumentError.value(batchNo, 'batchNo', '批次号不能为空');
    }
    await transaction(() async {
      final current = await customSelect(
        'SELECT batch_no FROM studio_inventory_batches '
        'WHERE id = ? AND workspace_id = ?',
        variables: [Variable(id), Variable(workspaceId)],
      ).getSingleOrNull();
      if (current == null) throw StateError('入库批次不存在或不属于当前农场');
      final oldBatchNo = current.read<String>('batch_no');
      await customUpdate(
        'UPDATE studio_inventory_batches SET batch_no = ?, supplier = ?, '
        'received_at = ?, note = ?, member_id = ?, updated_at = ? '
        'WHERE id = ? AND workspace_id = ?',
        variables: [
          Variable(normalizedBatchNo),
          Variable(_nullable(supplier)),
          Variable(receivedAt.millisecondsSinceEpoch),
          Variable(_nullable(note)),
          Variable(_nullable(memberId)),
          Variable(DateTime.now().millisecondsSinceEpoch),
          Variable(id),
          Variable(workspaceId),
        ],
      );
      if (oldBatchNo != normalizedBatchNo) {
        await customUpdate(
          'UPDATE consumables SET batch_no = ?, updated_at = ? '
          'WHERE id IN (SELECT consumable_id FROM studio_inventory_batch_items '
          'WHERE batch_id = ?)',
          variables: [
            Variable(normalizedBatchNo),
            Variable(_driftNowSeconds()),
            Variable(id),
          ],
          updates: {db.consumables},
        );
      }
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'inventory.batch_updated',
      entityType: 'inventory_batch',
      entityId: id,
      summary: '更新入库批次 $normalizedBatchNo',
      notify: false,
    );
    _emit();
  }

  /// Adjusts the physical roll count recorded by an inbound batch.
  ///
  /// Roll quantity is a batch fact, so it is deliberately not exposed from
  /// the inventory-roll view. Each farm roll is fixed at 1000g, and legacy
  /// batch rows are normalized to that value when their roll count is edited.
  Future<void> updateInventoryBatchRollCounts({
    required String batchId,
    required String workspaceId,
    required Map<String, int> rollCountsByItem,
    String? memberId,
  }) async {
    if (rollCountsByItem.isEmpty ||
        rollCountsByItem.values.any((value) => value <= 0 || value > 500)) {
      throw ArgumentError('每条批次明细的卷数必须是 1-500 卷');
    }
    await transaction(() async {
      final batch = await customSelect(
        'SELECT id FROM studio_inventory_batches '
        'WHERE id = ? AND workspace_id = ?',
        variables: [Variable(batchId), Variable(workspaceId)],
      ).getSingleOrNull();
      if (batch == null) throw StateError('入库批次不存在或不属于当前农场');
      final rows = await customSelect(
        'SELECT bi.id, bi.consumable_id, bi.roll_count, '
        'c.total_grams, c.remaining_grams '
        'FROM studio_inventory_batch_items bi '
        'JOIN consumables c ON c.id = bi.consumable_id '
        'WHERE bi.batch_id = ? AND bi.voided = 0',
        variables: [Variable(batchId)],
      ).get();
      if (rows.length != rollCountsByItem.length ||
          rows.any(
            (row) => !rollCountsByItem.containsKey(row.read<String>('id')),
          )) {
        throw StateError('批次明细已变化，请刷新后重试');
      }
      for (final row in rows) {
        final itemId = row.read<String>('id');
        final nextRolls = rollCountsByItem[itemId]!;
        final oldRolls = row.read<int>('roll_count');
        final oldTotal = row.read<double>('total_grams');
        final oldRemaining = row.read<double>('remaining_grams');
        final consumed = math.max(0.0, oldTotal - oldRemaining);
        final nextTotal = nextRolls * _farmRollGrams;
        final nextRemaining = (nextTotal - consumed).clamp(0.0, nextTotal);
        final inventoryDelta = nextRemaining - oldRemaining;
        await customUpdate(
          'UPDATE studio_inventory_batch_items SET roll_count = ?, '
          'grams_per_roll = ?, updated_at = ? WHERE id = ?',
          variables: [
            Variable(nextRolls),
            const Variable(_farmRollGrams),
            Variable(DateTime.now().millisecondsSinceEpoch),
            Variable(itemId),
          ],
        );
        await customUpdate(
          'UPDATE consumables SET total_grams = ?, remaining_grams = ?, '
          'updated_at = ? WHERE id = ? AND inventory_scope = \'farm\' '
          'AND farm_workspace_id = ?',
          variables: [
            Variable(nextTotal),
            Variable(nextRemaining),
            Variable(_driftNowSeconds()),
            Variable(row.read<int>('consumable_id')),
            Variable(workspaceId),
          ],
          updates: {db.consumables},
        );
        if (inventoryDelta.abs() > .0001 || oldRolls != nextRolls) {
          await customInsert(
            'INSERT INTO studio_inventory_events '
            '(id, workspace_id, consumable_id, event_type, delta_grams, reason, member_id, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            variables: [
              Variable(_uuid.v4()),
              Variable(workspaceId),
              Variable(row.read<int>('consumable_id')),
              Variable(StudioInventoryEventType.adjustment.name),
              Variable(inventoryDelta),
              Variable('批次卷数调整：$oldRolls → $nextRolls 卷'),
              Variable(_nullable(memberId)),
              Variable(DateTime.now().millisecondsSinceEpoch),
            ],
          );
        }
      }
      await customUpdate(
        'UPDATE studio_inventory_batches SET roll_count = '
        '(SELECT COALESCE(SUM(roll_count), 0) FROM studio_inventory_batch_items '
        'WHERE batch_id = ? AND voided = 0), total_grams = '
        '(SELECT COALESCE(SUM(roll_count * $_farmRollGrams), 0) '
        'FROM studio_inventory_batch_items WHERE batch_id = ? AND voided = 0), '
        'updated_at = ? WHERE id = ? AND EXISTS ('
        'SELECT 1 FROM studio_inventory_batch_items '
        'WHERE batch_id = ? AND voided = 0)',
        variables: [
          Variable(batchId),
          Variable(batchId),
          Variable(DateTime.now().millisecondsSinceEpoch),
          Variable(batchId),
          Variable(batchId),
        ],
      );
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'inventory.batch_rolls_updated',
      entityType: 'inventory_batch',
      entityId: batchId,
      summary: '调整批次卷数',
      notify: false,
    );
    _emit();
  }

  /// 冲销误入库明细。明细和原始入库量永久保留用于审计，仓库可用量归零并归档。
  Future<void> voidInventoryBatchItem({
    required String itemId,
    required String workspaceId,
    required String reason,
    String? memberId,
  }) async {
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty) {
      throw ArgumentError.value(reason, 'reason', '冲销原因不能为空');
    }
    late String batchId;
    late int consumableId;
    var changed = false;
    await transaction(() async {
      final row = await customSelect(
        'SELECT item.batch_id, item.consumable_id, item.voided, '
        'consumable.remaining_grams FROM studio_inventory_batch_items item '
        'JOIN studio_inventory_batches batch ON batch.id = item.batch_id '
        'JOIN consumables consumable ON consumable.id = item.consumable_id '
        'WHERE item.id = ? AND batch.workspace_id = ?',
        variables: [Variable(itemId), Variable(workspaceId)],
      ).getSingleOrNull();
      if (row == null) throw StateError('入库明细不存在或不属于当前农场');
      if (row.read<int>('voided') == 1) return;
      changed = true;
      batchId = row.read<String>('batch_id');
      consumableId = row.read<int>('consumable_id');
      final remaining = row.read<double>('remaining_grams');
      final now = DateTime.now();
      final nowMillis = now.millisecondsSinceEpoch;
      final nowSeconds = nowMillis ~/ 1000;
      await customUpdate(
        'UPDATE studio_inventory_batch_items SET voided = 1, '
        'void_reason = ?, voided_at = ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable(normalizedReason),
          Variable(nowMillis),
          Variable(nowMillis),
          Variable(itemId),
        ],
      );
      await customUpdate(
        'UPDATE consumables SET remaining_grams = 0, archived = 1, '
        'archived_at = ?, updated_at = ? WHERE id = ? '
        "AND inventory_scope = 'farm' AND farm_workspace_id = ?",
        variables: [
          Variable(nowSeconds),
          Variable(nowSeconds),
          Variable(consumableId),
          Variable(workspaceId),
        ],
        updates: {db.consumables},
      );
      await customInsert(
        'INSERT INTO studio_inventory_events '
        '(id, workspace_id, consumable_id, event_type, delta_grams, reason, '
        'member_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(_uuid.v4()),
          Variable(workspaceId),
          Variable(consumableId),
          Variable(StudioInventoryEventType.adjustment.name),
          Variable(-remaining),
          Variable('冲销入库明细：$normalizedReason'),
          Variable(_nullable(memberId)),
          Variable(nowMillis),
        ],
      );
      await customUpdate(
        'UPDATE studio_inventory_batches SET roll_count = '
        '(SELECT COALESCE(SUM(roll_count), 0) FROM studio_inventory_batch_items '
        'WHERE batch_id = ? AND voided = 0), total_grams = '
        '(SELECT COALESCE(SUM(roll_count * grams_per_roll), 0) '
        'FROM studio_inventory_batch_items WHERE batch_id = ? AND voided = 0), '
        'updated_at = ? WHERE id = ? AND EXISTS ('
        'SELECT 1 FROM studio_inventory_batch_items '
        'WHERE batch_id = ? AND voided = 0)',
        variables: [
          Variable(batchId),
          Variable(batchId),
          Variable(nowMillis),
          Variable(batchId),
          Variable(batchId),
        ],
      );
    });
    if (!changed) return;
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'inventory.batch_item_voided',
      entityType: 'inventory_batch_item',
      entityId: itemId,
      summary: '冲销入库明细 · $normalizedReason',
      notify: false,
    );
    _emit();
  }

  /// Deletes an inbound batch only while it is still completely unused.
  ///
  /// Batch deletion is intentionally stricter than editing its roll count:
  /// once any stock has left the warehouse, been loaded on a printer, or been
  /// referenced by a work order, its production history must be preserved.
  Future<void> deleteInventoryBatch({
    required String batchId,
    required String workspaceId,
  }) async {
    late String batchNo;
    await transaction(() async {
      final batch = await customSelect(
        'SELECT batch_no FROM studio_inventory_batches '
        'WHERE id = ? AND workspace_id = ?',
        variables: [Variable(batchId), Variable(workspaceId)],
      ).getSingleOrNull();
      if (batch == null) {
        throw StateError('入库批次不存在或不属于当前农场');
      }
      batchNo = batch.read<String>('batch_no');

      final rows = await customSelect(
        'SELECT c.id, c.total_grams, c.remaining_grams, '
        '(SELECT COUNT(*) FROM printer_channels pc '
        'WHERE pc.consumable_id = c.id) AS printer_refs, '
        '(SELECT COUNT(*) FROM studio_work_order_materials wm '
        'WHERE wm.consumable_id = c.id AND wm.workspace_id = ?) '
        'AS work_order_refs '
        'FROM studio_inventory_batch_items bi '
        'JOIN consumables c ON c.id = bi.consumable_id '
        'WHERE bi.batch_id = ? AND c.inventory_scope = \'farm\' '
        'AND c.farm_workspace_id = ?',
        variables: [
          Variable(workspaceId),
          Variable(batchId),
          Variable(workspaceId),
        ],
      ).get();

      final matchingStock = await customSelect(
        'SELECT COUNT(*) AS count FROM consumables '
        "WHERE inventory_scope = 'farm' AND farm_workspace_id = ? "
        'AND trim(COALESCE(batch_no, \'\')) = trim(?)',
        variables: [Variable(workspaceId), Variable(batchNo)],
      ).getSingle();
      if (rows.length != matchingStock.read<int>('count')) {
        throw StateError('该批次的库存明细关联不完整，请重启软件完成修复后再删除');
      }

      final installed = rows.any((row) => row.read<int>('printer_refs') > 0);
      if (installed) {
        throw StateError('该批次已有耗材装入打印机，不能删除');
      }
      final referenced = rows.any(
        (row) => row.read<int>('work_order_refs') > 0,
      );
      if (referenced) {
        throw StateError('该批次已有耗材被生产工单引用，不能删除');
      }
      final stockChanged = rows.any(
        (row) =>
            (row.read<double>('total_grams') -
                    row.read<double>('remaining_grams'))
                .abs() >
            .0001,
      );
      if (stockChanged) {
        throw StateError('该批次库存已经发生变化，不能删除；请保留批次并归档库存');
      }

      for (final row in rows) {
        await customUpdate(
          'DELETE FROM consumables WHERE id = ? '
          "AND inventory_scope = 'farm' AND farm_workspace_id = ?",
          variables: [Variable(row.read<int>('id')), Variable(workspaceId)],
          updates: {db.consumables},
        );
      }
      await customUpdate(
        'DELETE FROM studio_inventory_batches '
        'WHERE id = ? AND workspace_id = ?',
        variables: [Variable(batchId), Variable(workspaceId)],
      );
      await recordSyncDeletion(
        workspaceId: workspaceId,
        entityType: 'inventoryBatch',
        entityId: batchId,
        notify: false,
      );
    });
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'inventory.batch_deleted',
      entityType: 'inventory_batch',
      entityId: batchId,
      summary: '删除未使用入库批次 $batchNo',
      notify: false,
    );
    _emit();
  }

  Future<String> saveShareLink({
    String? id,
    required String workspaceId,
    required String orderId,
    required String tokenPreview,
    String? publicUrl,
    DateTime? expiresAt,
    bool passwordRequired = true,
  }) async {
    final linkId = id ?? _uuid.v4();
    await customInsert(
      'INSERT INTO studio_share_links '
      '(id, workspace_id, order_id, token_preview, public_url, active, expires_at, password_required, created_at) '
      'VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)',
      variables: [
        Variable(linkId),
        Variable(workspaceId),
        Variable(orderId),
        Variable(tokenPreview),
        Variable(_nullable(publicUrl)),
        Variable(expiresAt?.millisecondsSinceEpoch),
        Variable(passwordRequired ? 1 : 0),
        Variable(DateTime.now().millisecondsSinceEpoch),
      ],
    );
    await recordActivity(
      workspaceId: workspaceId,
      actionCode: 'share_link.created',
      entityType: 'order',
      entityId: orderId,
      summary: '创建客户查看链接',
      notify: false,
    );
    _emit();
    return linkId;
  }

  Future<void> revokeShareLink(String id) async {
    final row = await customSelect(
      'SELECT workspace_id, order_id FROM studio_share_links WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    await customUpdate(
      'UPDATE studio_share_links SET active = 0 WHERE id = ?',
      variables: [Variable(id)],
    );
    if (row != null) {
      await recordActivity(
        workspaceId: row.read<String>('workspace_id'),
        actionCode: 'share_link.revoked',
        entityType: 'order',
        entityId: row.read<String>('order_id'),
        summary: '撤销客户查看链接',
        notify: false,
      );
    }
    _emit();
  }

  Future<void> mergeRemoteShareLinks(
    List<Map<String, dynamic>> links, {
    bool notify = true,
  }) async {
    final workspace = await ensureDefaultWorkspace();
    await transaction(() async {
      for (final item in links) {
        final id = _text(item['id']);
        final orderId = _text(item['orderId']);
        final tokenPreview = _text(item['tokenPreview']);
        if (id == null || orderId == null || tokenPreview == null) continue;
        final order = await customSelect(
          'SELECT id FROM studio_orders WHERE id = ? AND workspace_id = ?',
          variables: [Variable(orderId), Variable(workspace.id)],
        ).getSingleOrNull();
        if (order == null) continue;
        await customInsert(
          'INSERT INTO studio_share_links '
          '(id, workspace_id, order_id, token_preview, public_url, active, '
          'expires_at, password_required, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET token_preview = excluded.token_preview, '
          'public_url = COALESCE(excluded.public_url, studio_share_links.public_url), '
          'active = excluded.active, expires_at = excluded.expires_at, '
          'password_required = excluded.password_required',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(orderId),
            Variable(tokenPreview),
            Variable(_text(item['publicUrl'])),
            Variable(item['active'] == false ? 0 : 1),
            Variable(_remoteNullableDate(item['expiresAt'])),
            Variable(item['passwordRequired'] == false ? 0 : 1),
            Variable(_remoteDate(item['createdAt'])),
          ],
        );
      }
    });
    if (notify) _emit();
  }

  Future<void> recordSyncDeletion({
    required String workspaceId,
    required String entityType,
    required String entityId,
    bool notify = true,
  }) async {
    final deletedAt = DateTime.now().millisecondsSinceEpoch;
    await customInsert(
      'INSERT INTO studio_sync_tombstones '
      '(workspace_id, entity_type, entity_id, deleted_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(workspace_id, entity_type, entity_id) DO UPDATE SET '
      'deleted_at = MAX(deleted_at, excluded.deleted_at)',
      variables: [
        Variable(workspaceId),
        Variable(entityType),
        Variable(entityId),
        Variable(deletedAt),
      ],
    );
    if (notify) _emit();
  }

  Future<List<Map<String, dynamic>>> getSyncTombstones() async {
    final workspace = await ensureDefaultWorkspace();
    final rows = await customSelect(
      'SELECT entity_type, entity_id, deleted_at FROM studio_sync_tombstones '
      'WHERE workspace_id = ? ORDER BY deleted_at ASC',
      variables: [Variable(workspace.id)],
    ).get();
    return [
      for (final row in rows)
        {
          'entityType': row.read<String>('entity_type'),
          'entityId': row.read<String>('entity_id'),
          'deletedAt': _date(
            row.read<int>('deleted_at'),
          ).toUtc().toIso8601String(),
        },
    ];
  }

  Future<bool> _isSyncDeleted(
    String workspaceId,
    String entityType,
    String entityId,
    int entityUpdatedAt,
  ) async {
    final row = await customSelect(
      'SELECT deleted_at FROM studio_sync_tombstones '
      'WHERE workspace_id = ? AND entity_type = ? AND entity_id = ?',
      variables: [
        Variable(workspaceId),
        Variable(entityType),
        Variable(entityId),
      ],
    ).getSingleOrNull();
    return row != null && row.read<int>('deleted_at') >= entityUpdatedAt;
  }

  Future<void> _mergeRemoteTombstones(
    String workspaceId,
    Map<String, dynamic> snapshot,
  ) async {
    for (final item in _maps(snapshot['deletedEntities'])) {
      final entityType = _text(item['entityType']);
      final entityId = _text(item['entityId']);
      if (entityType == null || entityId == null) continue;
      final deletedAt = _remoteDate(item['deletedAt']);
      await customInsert(
        'INSERT INTO studio_sync_tombstones '
        '(workspace_id, entity_type, entity_id, deleted_at) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(workspace_id, entity_type, entity_id) DO UPDATE SET '
        'deleted_at = MAX(deleted_at, excluded.deleted_at)',
        variables: [
          Variable(workspaceId),
          Variable(entityType),
          Variable(entityId),
          Variable(deletedAt),
        ],
      );
      switch (entityType) {
        case 'inventoryItem':
          await customUpdate(
            'DELETE FROM consumables WHERE uid = ? '
            "AND inventory_scope = 'farm' AND farm_workspace_id = ? "
            'AND updated_at * 1000 <= ?',
            variables: [
              Variable(entityId),
              Variable(workspaceId),
              Variable(deletedAt),
            ],
            updates: {db.consumables},
          );
        case 'inventoryBatch':
          await customUpdate(
            'DELETE FROM studio_inventory_batches WHERE id = ? '
            'AND workspace_id = ? AND updated_at <= ?',
            variables: [
              Variable(entityId),
              Variable(workspaceId),
              Variable(deletedAt),
            ],
          );
        case 'workOrderMaterial':
          await customUpdate(
            'DELETE FROM studio_work_order_materials WHERE id = ? '
            'AND workspace_id = ? AND updated_at <= ?',
            variables: [
              Variable(entityId),
              Variable(workspaceId),
              Variable(deletedAt),
            ],
          );
      }
    }
  }

  Future<void> mergeRemoteSnapshot(
    Map<String, dynamic> snapshot, {
    bool notify = true,
  }) async {
    final workspace = await ensureDefaultWorkspace();
    await transaction(() async {
      await _mergeRemoteTombstones(workspace.id, snapshot);
      for (final item in _maps(snapshot['inventoryItems'])) {
        final uid = _text(item['uid']);
        if (uid == null) continue;
        final updatedAt = _remoteDriftDate(item['updatedAt']);
        if (await _isSyncDeleted(
          workspace.id,
          'inventoryItem',
          uid,
          updatedAt * 1000,
        )) {
          continue;
        }
        final existing = await customSelect(
          'SELECT id, updated_at FROM consumables WHERE uid = ? '
          "AND inventory_scope = 'farm' AND farm_workspace_id = ?",
          variables: [Variable(uid), Variable(workspace.id)],
        ).getSingleOrNull();
        if (existing == null) {
          final createdAt = _remoteDriftDate(
            item['createdAt'],
            fallback: updatedAt,
          );
          await customInsert(
            'INSERT INTO consumables '
            '(uid, manufacturer, model, material_type, color_hex, color_name, '
            'total_grams, remaining_grams, batch_no, purchase_date, created_at, '
            'updated_at, inventory_scope, farm_workspace_id, archived, archived_at, '
            'brand_code, color_mode, secondary_color_hex) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            variables: [
              Variable(uid),
              Variable(_text(item['manufacturer']) ?? '第三方'),
              Variable(_text(item['model']) ?? ''),
              Variable(_text(item['materialType']) ?? 'PLA'),
              Variable(_text(item['colorHex']) ?? '#808080'),
              Variable(_text(item['colorName'])),
              Variable(_number(item['totalGrams'])),
              Variable(_number(item['remainingGrams'])),
              Variable(_text(item['batchNo'])),
              Variable(_remoteNullableDriftDate(item['purchaseDate'])),
              Variable(createdAt),
              Variable(updatedAt),
              const Variable('farm'),
              Variable(workspace.id),
              Variable(item['archived'] == true ? 1 : 0),
              Variable(_remoteNullableDriftDate(item['archivedAt'])),
              Variable(_text(item['brandCode'])),
              Variable(_text(item['colorMode']) ?? 'solid'),
              Variable(_text(item['secondaryColorHex'])),
            ],
          );
        } else if (updatedAt > existing.read<int>('updated_at')) {
          await customUpdate(
            'UPDATE consumables SET manufacturer = ?, model = ?, material_type = ?, '
            'color_hex = ?, color_name = ?, total_grams = ?, remaining_grams = ?, '
            'batch_no = ?, purchase_date = ?, archived = ?, archived_at = ?, '
            'brand_code = ?, color_mode = ?, secondary_color_hex = ?, updated_at = ? '
            'WHERE id = ?',
            variables: [
              Variable(_text(item['manufacturer']) ?? '第三方'),
              Variable(_text(item['model']) ?? ''),
              Variable(_text(item['materialType']) ?? 'PLA'),
              Variable(_text(item['colorHex']) ?? '#808080'),
              Variable(_text(item['colorName'])),
              Variable(_number(item['totalGrams'])),
              Variable(_number(item['remainingGrams'])),
              Variable(_text(item['batchNo'])),
              Variable(_remoteNullableDriftDate(item['purchaseDate'])),
              Variable(item['archived'] == true ? 1 : 0),
              Variable(_remoteNullableDriftDate(item['archivedAt'])),
              Variable(_text(item['brandCode'])),
              Variable(_text(item['colorMode']) ?? 'solid'),
              Variable(_text(item['secondaryColorHex'])),
              Variable(updatedAt),
              Variable(existing.read<int>('id')),
            ],
            updates: {db.consumables},
          );
        }
      }

      for (final item in _maps(snapshot['customers'])) {
        final id = _text(item['id']);
        if (id == null) continue;
        final updatedAt = _remoteDate(item['updatedAt']);
        await customInsert(
          'INSERT INTO studio_customers '
          '(id, workspace_id, name, contact_name, phone, email, note, archived, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, contact_name = excluded.contact_name, '
          'phone = excluded.phone, email = excluded.email, note = excluded.note, archived = excluded.archived, '
          'updated_at = excluded.updated_at WHERE excluded.updated_at > studio_customers.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(_text(item['name']) ?? '未命名客户'),
            Variable(_text(item['contactName'])),
            Variable(_text(item['phone'])),
            Variable(_text(item['email'])),
            Variable(_text(item['note'])),
            Variable(item['archived'] == true ? 1 : 0),
            Variable(_remoteDate(item['createdAt'], fallback: updatedAt)),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['orders'])) {
        final id = _text(item['id']);
        if (id == null) continue;
        final updatedAt = _remoteDate(item['updatedAt']);
        await customInsert(
          'INSERT INTO studio_orders '
          '(id, workspace_id, customer_id, order_no, title, status, due_at, total_price, note, public_note, portal_video_enabled, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET customer_id = excluded.customer_id, order_no = excluded.order_no, '
          'title = excluded.title, status = excluded.status, due_at = excluded.due_at, '
          'total_price = excluded.total_price, note = excluded.note, public_note = excluded.public_note, '
          'portal_video_enabled = excluded.portal_video_enabled, updated_at = excluded.updated_at '
          'WHERE excluded.updated_at > studio_orders.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(_text(item['customerId'])),
            Variable(
              _text(item['orderNo']) ?? id.substring(0, math.min(8, id.length)),
            ),
            Variable(_text(item['title']) ?? '未命名订单'),
            Variable(_text(item['status']) ?? StudioOrderStatus.draft.name),
            Variable(_remoteNullableDate(item['dueAt'])),
            Variable(_number(item['totalPrice'])),
            Variable(_text(item['note'])),
            Variable(_text(item['publicNote'])),
            Variable(item['portalVideoEnabled'] == false ? 0 : 1),
            Variable(_remoteDate(item['createdAt'], fallback: updatedAt)),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['productionPackages'])) {
        final id = _text(item['id']);
        final orderId = _text(item['orderId']);
        if (id == null || orderId == null) continue;
        await customInsert(
          'INSERT INTO studio_production_packages '
          '(id, workspace_id, order_id, source_name, artifact_sha256, artifact_kind, slicer_name, slicer_version, target_model, nozzle_diameter, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET source_name = excluded.source_name, '
          'artifact_sha256 = COALESCE(excluded.artifact_sha256, studio_production_packages.artifact_sha256), '
          'artifact_kind = excluded.artifact_kind, slicer_name = excluded.slicer_name, '
          'slicer_version = excluded.slicer_version, target_model = excluded.target_model, '
          'nozzle_diameter = excluded.nozzle_diameter',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(orderId),
            Variable(_text(item['sourceName']) ?? '切片生产包'),
            Variable(_text(item['artifactSha256'])),
            Variable(_text(item['artifactKind']) ?? 'bambu3mf'),
            Variable(_text(item['slicerName'])),
            Variable(_text(item['slicerVersion'])),
            Variable(_text(item['targetModel'])),
            Variable(
              item['nozzleDiameter'] == null
                  ? null
                  : _number(item['nozzleDiameter']),
            ),
            Variable(_remoteDate(item['createdAt'])),
          ],
        );
      }

      for (final item in _maps(snapshot['productionPlates'])) {
        final id = _text(item['id']);
        final orderId = _text(item['orderId']);
        final packageId = _text(item['packageId']);
        if (id == null || orderId == null || packageId == null) continue;
        final updatedAt = _remoteDate(
          item['updatedAt'],
          fallback: _remoteDate(item['createdAt']),
        );
        if (await _isSyncDeleted(
          workspace.id,
          'productionPlate',
          id,
          updatedAt,
        )) {
          continue;
        }
        await customInsert(
          'INSERT INTO studio_production_plates '
          '(id, workspace_id, order_id, package_id, plate_index, name, required_runs, estimated_seconds, estimated_grams, slice_status, slice_artifact_sha256, auto_eject_enabled, total_layers, tool_change_count, filament_usage_json, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, required_runs = excluded.required_runs, '
          'estimated_seconds = excluded.estimated_seconds, estimated_grams = excluded.estimated_grams, '
          'slice_status = excluded.slice_status, slice_artifact_sha256 = excluded.slice_artifact_sha256, '
          'auto_eject_enabled = excluded.auto_eject_enabled, '
          'total_layers = excluded.total_layers, tool_change_count = excluded.tool_change_count, '
          'filament_usage_json = excluded.filament_usage_json, updated_at = excluded.updated_at '
          'WHERE excluded.updated_at > studio_production_plates.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(orderId),
            Variable(packageId),
            Variable(math.max(1, _integer(item['plateIndex']))),
            Variable(_text(item['name']) ?? '生产盘'),
            Variable(math.max(1, _integer(item['requiredRuns']))),
            Variable(math.max(0, _integer(item['estimatedSeconds']))),
            Variable(math.max(0, _number(item['estimatedGrams']))),
            Variable(
              StudioPlateSliceStatus.fromCode(
                _text(item['sliceStatus']) ?? 'pending',
              ).name,
            ),
            Variable(_text(item['sliceArtifactSha256'])),
            Variable(switch (item['autoEjectEnabled']) {
              true => 1,
              false => 0,
              _ => null,
            }),
            Variable(math.max(0, _integer(item['totalLayers']))),
            Variable(math.max(0, _integer(item['toolChangeCount']))),
            Variable(_encodeRemoteFilaments(item['filaments'])),
            Variable(_remoteDate(item['createdAt'])),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['orderItems'])) {
        final id = _text(item['id']);
        final orderId = _text(item['orderId']);
        final packageId = _text(item['packageId']);
        final plateId = _text(item['plateId']);
        if (id == null ||
            orderId == null ||
            packageId == null ||
            plateId == null) {
          continue;
        }
        await customInsert(
          'INSERT INTO studio_order_items '
          '(id, workspace_id, order_id, package_id, plate_id, source_key, name, per_run_quantity, required_quantity, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'per_run_quantity = excluded.per_run_quantity, required_quantity = excluded.required_quantity',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(orderId),
            Variable(packageId),
            Variable(plateId),
            Variable(_text(item['sourceKey']) ?? id),
            Variable(_text(item['name']) ?? '成品项'),
            Variable(math.max(1, _integer(item['perRunQuantity']))),
            Variable(math.max(1, _integer(item['requiredQuantity']))),
            Variable(_remoteDate(item['createdAt'])),
          ],
        );
      }

      for (final item in _maps(snapshot['workOrders'])) {
        final id = _text(item['id']);
        final orderId = _text(item['orderId']);
        if (id == null || orderId == null) continue;
        final updatedAt = _remoteDate(item['updatedAt']);
        final localPrinterId = await _localPrinterIdForRef(
          _text(item['printerRef']),
        );
        await customInsert(
          'INSERT INTO studio_work_orders '
          '(id, workspace_id, order_id, production_plate_id, title, quantity, completed_quantity, status, '
          'assigned_member_id, printer_id, material_cost_snapshot, quoted_price_snapshot, note, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET title = excluded.title, quantity = excluded.quantity, '
          'completed_quantity = excluded.completed_quantity, status = excluded.status, '
          'production_plate_id = excluded.production_plate_id, '
          'assigned_member_id = excluded.assigned_member_id, '
          'printer_id = COALESCE(excluded.printer_id, studio_work_orders.printer_id), '
          'material_cost_snapshot = excluded.material_cost_snapshot, '
          'quoted_price_snapshot = excluded.quoted_price_snapshot, note = excluded.note, '
          'updated_at = excluded.updated_at WHERE excluded.updated_at > studio_work_orders.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(orderId),
            Variable(_text(item['productionPlateId'])),
            Variable(_text(item['title']) ?? '未命名工单'),
            Variable(math.max(1, _integer(item['quantity']))),
            Variable(math.max(0, _integer(item['completedQuantity']))),
            Variable(
              _text(item['status']) ?? StudioWorkOrderStatus.queued.name,
            ),
            Variable(_text(item['assignedMemberId'])),
            Variable(localPrinterId),
            Variable(_number(item['materialCostSnapshot'])),
            Variable(_number(item['quotedPriceSnapshot'])),
            Variable(_text(item['note'])),
            Variable(_remoteDate(item['createdAt'], fallback: updatedAt)),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['workOrderMaterials'])) {
        final id = _text(item['id']);
        final workOrderId = _text(item['workOrderId']);
        final productionPlateId = _text(item['productionPlateId']);
        if (id == null || workOrderId == null || productionPlateId == null) {
          continue;
        }
        final materialUpdatedAt = _remoteDate(item['updatedAt']);
        if (await _isSyncDeleted(
          workspace.id,
          'workOrderMaterial',
          id,
          materialUpdatedAt,
        )) {
          continue;
        }
        final consumableUid = _text(item['consumableUid']);
        final consumable = consumableUid == null
            ? null
            : await customSelect(
                'SELECT id FROM consumables WHERE uid = ? '
                "AND inventory_scope = 'farm' AND farm_workspace_id = ?",
                variables: [Variable(consumableUid), Variable(workspace.id)],
              ).getSingleOrNull();
        final requestedStatus = StudioWorkOrderMaterialStatus.fromCode(
          _text(item['status']) ?? 'unallocated',
        );
        final mappedConsumableId = consumable?.read<int>('id');
        var mappedPrinterChannelId = await _localPrinterChannelIdForRef(
          _text(item['printerChannelRef']),
        );
        if (mappedPrinterChannelId != null) {
          final binding = await customSelect(
            'SELECT consumable_id FROM printer_channels WHERE id = ?',
            variables: [Variable(mappedPrinterChannelId)],
          ).getSingleOrNull();
          if (binding?.read<int?>('consumable_id') != mappedConsumableId) {
            mappedPrinterChannelId = null;
          }
        }
        final effectiveStatus =
            requestedStatus == StudioWorkOrderMaterialStatus.reserved &&
                mappedConsumableId == null
            ? StudioWorkOrderMaterialStatus.unallocated
            : requestedStatus;
        final updatedAt = materialUpdatedAt;
        await customInsert(
          'INSERT INTO studio_work_order_materials '
          '(id, workspace_id, work_order_id, production_plate_id, tool_index, '
          'material_type, color_hex, sku, estimated_grams, consumable_id, '
          'printer_channel_id, reserved_grams, consumed_grams, status, created_at, updated_at, settled_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(work_order_id, tool_index) DO UPDATE SET '
          'material_type = excluded.material_type, color_hex = excluded.color_hex, '
          'sku = excluded.sku, estimated_grams = excluded.estimated_grams, '
          'consumable_id = excluded.consumable_id, '
          'printer_channel_id = COALESCE(excluded.printer_channel_id, studio_work_order_materials.printer_channel_id), '
          'reserved_grams = excluded.reserved_grams, '
          'consumed_grams = excluded.consumed_grams, status = excluded.status, '
          'updated_at = excluded.updated_at, settled_at = excluded.settled_at '
          'WHERE excluded.updated_at > studio_work_order_materials.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(workOrderId),
            Variable(productionPlateId),
            Variable(math.max(0, _integer(item['toolIndex']))),
            Variable(_text(item['materialType'])),
            Variable(_normalizedColor(_text(item['colorHex']))),
            Variable(_text(item['sku'])),
            Variable(math.max(0, _number(item['estimatedGrams']))),
            Variable(mappedConsumableId),
            Variable(mappedPrinterChannelId),
            Variable(
              effectiveStatus == StudioWorkOrderMaterialStatus.reserved
                  ? math.max(0, _number(item['reservedGrams']))
                  : 0,
            ),
            Variable(math.max(0, _number(item['consumedGrams']))),
            Variable(effectiveStatus.name),
            Variable(_remoteDate(item['createdAt'], fallback: updatedAt)),
            Variable(updatedAt),
            Variable(_remoteNullableDate(item['settledAt'])),
          ],
        );
      }

      for (final item in _maps(snapshot['printAttempts'])) {
        final id = _text(item['id']);
        final workOrderId = _text(item['workOrderId']);
        if (id == null || workOrderId == null) continue;
        final updatedAt = _remoteDate(item['updatedAt']);
        final localPrinterId = await _localPrinterIdForRef(
          _text(item['printerRef']),
        );
        final localPrinter = localPrinterId == null
            ? null
            : await customSelect(
                'SELECT serial FROM printers WHERE id = ?',
                variables: [Variable(localPrinterId)],
              ).getSingleOrNull();
        await customInsert(
          'INSERT INTO studio_print_attempts '
          '(id, workspace_id, work_order_id, print_queue_id, attempt_no, '
          'printer_serial, outcome, progress_percent, consumed_grams, '
          'material_cost, failure_reason, error_code, started_at, ended_at, '
          'created_at, updated_at) '
          'VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET outcome = excluded.outcome, '
          'progress_percent = excluded.progress_percent, '
          'consumed_grams = excluded.consumed_grams, '
          'material_cost = excluded.material_cost, '
          'failure_reason = excluded.failure_reason, '
          'error_code = excluded.error_code, ended_at = excluded.ended_at, '
          'updated_at = excluded.updated_at '
          'WHERE excluded.updated_at > studio_print_attempts.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(workOrderId),
            Variable(math.max(1, _integer(item['attemptNo']))),
            Variable(localPrinter?.read<String?>('serial')),
            Variable(
              StudioPrintAttemptOutcome.fromCode(
                _text(item['outcome']) ?? 'failed',
              ).code,
            ),
            Variable(
              item['progressPercent'] == null
                  ? null
                  : _integer(item['progressPercent']).clamp(0, 100),
            ),
            Variable(math.max(0, _number(item['consumedGrams']))),
            Variable(math.max(0, _number(item['materialCost']))),
            Variable(_text(item['failureReason'])),
            Variable(_text(item['errorCode'])),
            Variable(_remoteNullableDate(item['startedAt'])),
            Variable(_remoteDate(item['endedAt'])),
            Variable(_remoteDate(item['createdAt'], fallback: updatedAt)),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['quotes'])) {
        final id = _text(item['id']);
        if (id == null) continue;
        final updatedAt = _remoteDate(item['updatedAt']);
        await customInsert(
          'INSERT INTO studio_quotes '
          '(id, workspace_id, customer_id, order_id, quote_no, title, status, material_label, estimated_grams, '
          'material_cost_per_kg_snapshot, machine_hours, machine_rate_per_hour, labor_hours, '
          'labor_rate_per_hour, electricity_cost, packaging_cost, risk_percent, markup_percent, '
          'total_cost, quoted_price, note, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET customer_id = excluded.customer_id, order_id = excluded.order_id, quote_no = excluded.quote_no, '
          'title = excluded.title, status = excluded.status, material_label = excluded.material_label, '
          'estimated_grams = excluded.estimated_grams, '
          'material_cost_per_kg_snapshot = excluded.material_cost_per_kg_snapshot, '
          'machine_hours = excluded.machine_hours, machine_rate_per_hour = excluded.machine_rate_per_hour, '
          'labor_hours = excluded.labor_hours, labor_rate_per_hour = excluded.labor_rate_per_hour, '
          'electricity_cost = excluded.electricity_cost, packaging_cost = excluded.packaging_cost, '
          'risk_percent = excluded.risk_percent, markup_percent = excluded.markup_percent, '
          'total_cost = excluded.total_cost, quoted_price = excluded.quoted_price, note = excluded.note, '
          'updated_at = excluded.updated_at WHERE excluded.updated_at > studio_quotes.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(_text(item['customerId'])),
            Variable(_text(item['orderId'])),
            Variable(
              _text(item['quoteNo']) ?? id.substring(0, math.min(8, id.length)),
            ),
            Variable(_text(item['title']) ?? '未命名报价'),
            Variable(_text(item['status']) ?? StudioQuoteStatus.draft.name),
            Variable(_text(item['materialLabel']) ?? '未指定耗材'),
            Variable(_number(item['estimatedGrams'])),
            Variable(_number(item['materialCostPerKgSnapshot'])),
            Variable(_number(item['machineHours'])),
            Variable(_number(item['machineRatePerHour'])),
            Variable(_number(item['laborHours'])),
            Variable(_number(item['laborRatePerHour'])),
            Variable(_number(item['electricityCost'])),
            Variable(_number(item['packagingCost'])),
            Variable(_number(item['riskPercent'])),
            Variable(_number(item['markupPercent'])),
            Variable(_number(item['totalCost'])),
            Variable(_number(item['quotedPrice'])),
            Variable(_text(item['note'])),
            Variable(_remoteDate(item['createdAt'], fallback: updatedAt)),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['inventoryEvents'])) {
        final id = _text(item['id']);
        final consumableUid = _text(item['consumableUid']);
        if (id == null || consumableUid == null) continue;
        final consumable = await customSelect(
          'SELECT id FROM consumables WHERE uid = ?',
          variables: [Variable(consumableUid)],
        ).getSingleOrNull();
        if (consumable == null) continue;
        await customInsert(
          'INSERT OR IGNORE INTO studio_inventory_events '
          '(id, workspace_id, consumable_id, event_type, delta_grams, reason, member_id, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(consumable.read<int>('id')),
            Variable(
              _text(item['type']) ?? StudioInventoryEventType.adjustment.name,
            ),
            Variable(_number(item['deltaGrams'])),
            Variable(_text(item['reason']) ?? '云端同步'),
            Variable(_text(item['memberId'])),
            Variable(_remoteDate(item['createdAt'])),
          ],
        );
      }

      for (final item in _maps(snapshot['inventoryBatches'])) {
        final id = _text(item['id']);
        final batchNo = _text(item['batchNo']);
        if (id == null || batchNo == null) continue;
        final updatedAt = _remoteDate(
          item['updatedAt'],
          fallback: _remoteDate(item['createdAt']),
        );
        if (await _isSyncDeleted(
          workspace.id,
          'inventoryBatch',
          id,
          updatedAt,
        )) {
          continue;
        }
        await customInsert(
          'INSERT INTO studio_inventory_batches '
          '(id, workspace_id, batch_no, supplier, received_at, roll_count, total_grams, note, member_id, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(workspace_id, batch_no) DO UPDATE SET '
          'supplier = excluded.supplier, received_at = excluded.received_at, '
          'roll_count = excluded.roll_count, total_grams = excluded.total_grams, '
          'note = excluded.note, member_id = excluded.member_id, '
          'updated_at = excluded.updated_at '
          'WHERE excluded.updated_at > studio_inventory_batches.updated_at',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(batchNo),
            Variable(_text(item['supplier'])),
            Variable(_remoteDate(item['receivedAt'])),
            Variable(math.max(1, _integer(item['rollCount']))),
            Variable(math.max(0.1, _number(item['totalGrams']))),
            Variable(_text(item['note'])),
            Variable(_text(item['memberId'])),
            Variable(_remoteDate(item['createdAt'])),
            Variable(updatedAt),
          ],
        );
      }

      for (final item in _maps(snapshot['inventoryBatchItems'])) {
        final id = _text(item['id']);
        final batchId = _text(item['batchId']);
        final consumableUid = _text(item['consumableUid']);
        if (id == null || batchId == null || consumableUid == null) continue;
        final batch = await customSelect(
          'SELECT id FROM studio_inventory_batches '
          'WHERE id = ? AND workspace_id = ? LIMIT 1',
          variables: [Variable(batchId), Variable(workspace.id)],
        ).getSingleOrNull();
        final consumable = await customSelect(
          'SELECT id FROM consumables WHERE uid = ? '
          "AND inventory_scope = 'farm' AND farm_workspace_id = ? LIMIT 1",
          variables: [Variable(consumableUid), Variable(workspace.id)],
        ).getSingleOrNull();
        if (batch == null || consumable == null) continue;
        final updatedAt = _remoteDate(
          item['updatedAt'],
          fallback: _remoteDate(item['createdAt']),
        );
        if (await _isSyncDeleted(
          workspace.id,
          'inventoryBatchItem',
          id,
          updatedAt,
        )) {
          continue;
        }
        await customInsert(
          'INSERT INTO studio_inventory_batch_items '
          '(id, batch_id, consumable_id, roll_count, grams_per_roll, unit_cost, '
          'voided, void_reason, voided_at, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(consumable_id) DO UPDATE SET '
          'batch_id = excluded.batch_id, roll_count = excluded.roll_count, '
          'grams_per_roll = excluded.grams_per_roll, unit_cost = excluded.unit_cost, '
          'voided = excluded.voided, void_reason = excluded.void_reason, '
          'voided_at = excluded.voided_at, '
          'updated_at = excluded.updated_at '
          'WHERE excluded.updated_at > studio_inventory_batch_items.updated_at',
          variables: [
            Variable(id),
            Variable(batchId),
            Variable(consumable.read<int>('id')),
            Variable(math.max(1, _integer(item['rollCount']))),
            Variable(math.max(0.1, _number(item['gramsPerRoll']))),
            Variable(math.max(0, _number(item['unitCost']))),
            Variable(item['voided'] == true ? 1 : 0),
            Variable(_text(item['voidReason'])),
            Variable(_remoteNullableDate(item['voidedAt'])),
            Variable(_remoteDate(item['createdAt'])),
            Variable(updatedAt),
          ],
        );
      }
      await _reconcileInventoryBatchTotals(workspace.id);

      for (final item in _maps(snapshot['activityEvents'])) {
        final id = _text(item['id']);
        final entityType = _text(item['entityType']);
        final entityId = _text(item['entityId']);
        if (id == null || entityType == null || entityId == null) continue;
        await customInsert(
          'INSERT OR IGNORE INTO studio_activity_events '
          '(id, workspace_id, actor_member_id, actor_display_name, actor_identity, '
          'action_code, entity_type, entity_id, summary, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(id),
            Variable(workspace.id),
            Variable(_text(item['actorMemberId'])),
            Variable(_text(item['actorDisplayName']) ?? '管理员'),
            Variable(
              _text(item['actorIdentity']) == 'member'
                  ? 'member'
                  : 'administrator',
            ),
            Variable(_text(item['actionCode']) ?? 'entity.updated'),
            Variable(entityType),
            Variable(entityId),
            Variable(_text(item['summary']) ?? '更新记录'),
            Variable(_remoteDate(item['createdAt'])),
          ],
        );
      }
    });
    if (notify) _emit();
  }

  Future<void> mergeRemoteMembers(
    List<Map<String, dynamic>> members, {
    bool notify = true,
  }) async {
    final workspace = await ensureDefaultWorkspace();
    await transaction(() async {
      for (final item in members) {
        final email = _text(item['email']);
        final remoteId = _text(item['id']);
        final loginName = _text(item['loginName']);
        final role = StudioMemberRole.fromCode(
          _text(item['role']) ?? 'operator',
        );
        if (role == StudioMemberRole.owner) {
          await customUpdate(
            'UPDATE studio_members SET display_name = ?, email = ?, '
            "account_status = 'active', primary_role_code = 'owner', "
            "role_codes_json = '[\"owner\"]' "
            "WHERE workspace_id = ? AND role = 'owner'",
            variables: [
              Variable(_text(item['displayName']) ?? '工作室所有者'),
              Variable(email),
              Variable(workspace.id),
            ],
          );
          continue;
        }
        QueryRow? existing;
        if (remoteId != null) {
          existing = await customSelect(
            'SELECT id FROM studio_members WHERE id = ? LIMIT 1',
            variables: [Variable(remoteId)],
          ).getSingleOrNull();
        }
        if (existing == null && loginName != null) {
          existing = await customSelect(
            'SELECT id FROM studio_members WHERE workspace_id = ? '
            'AND lower(login_name) = lower(?) LIMIT 1',
            variables: [Variable(workspace.id), Variable(loginName)],
          ).getSingleOrNull();
        }
        if (existing == null && email != null) {
          existing = await customSelect(
            'SELECT id FROM studio_members WHERE workspace_id = ? '
            'AND lower(email) = lower(?) LIMIT 1',
            variables: [Variable(workspace.id), Variable(email)],
          ).getSingleOrNull();
        }
        final displayName =
            _text(item['displayName']) ?? loginName ?? email ?? '农场成员';
        final accountStatus =
            _text(item['accountStatus']) ??
            (item['active'] == false ? 'deactivated' : 'active');
        const primaryRoleCode = 'member';
        final roleCodes = <String>['member'];
        if (existing != null) {
          await customUpdate(
            'UPDATE studio_members SET display_name = ?, email = ?, role = ?, '
            'active = ?, login_name = ?, employee_no = ?, phone = ?, '
            'recovery_email = ?, account_status = ?, primary_role_code = ?, '
            'role_codes_json = ?, must_change_password = ?, last_login_at = ?, '
            'deactivated_at = ? '
            'WHERE id = ?',
            variables: [
              Variable(displayName),
              Variable(email),
              const Variable('operator'),
              Variable(item['active'] == false ? 0 : 1),
              Variable(loginName),
              Variable(_text(item['employeeNo'])),
              Variable(_text(item['phone'])),
              Variable(_text(item['recoveryEmail'])),
              Variable(accountStatus),
              Variable(primaryRoleCode),
              Variable(jsonEncode(roleCodes)),
              Variable(item['mustChangePassword'] == true ? 1 : 0),
              Variable(_remoteNullableDate(item['lastLoginAt'])),
              Variable(_remoteNullableDate(item['deactivatedAt'])),
              Variable(existing.read<String>('id')),
            ],
          );
        } else {
          await customInsert(
            'INSERT INTO studio_members '
            '(id, workspace_id, display_name, email, role, active, created_at, '
            'login_name, employee_no, phone, recovery_email, account_status, '
            'primary_role_code, role_codes_json, must_change_password, '
            'last_login_at, deactivated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            variables: [
              Variable(remoteId ?? _uuid.v4()),
              Variable(workspace.id),
              Variable(displayName),
              Variable(email),
              const Variable('operator'),
              Variable(item['active'] == false ? 0 : 1),
              Variable(_remoteDate(item['createdAt'])),
              Variable(loginName),
              Variable(_text(item['employeeNo'])),
              Variable(_text(item['phone'])),
              Variable(_text(item['recoveryEmail'])),
              Variable(accountStatus),
              Variable(primaryRoleCode),
              Variable(jsonEncode(roleCodes)),
              Variable(item['mustChangePassword'] == true ? 1 : 0),
              Variable(_remoteNullableDate(item['lastLoginAt'])),
              Variable(_remoteNullableDate(item['deactivatedAt'])),
            ],
          );
        }
      }
    });
    if (notify) _emit();
  }

  Future<void> _reconcileOrderStatus(String orderId) async {
    final rows = await customSelect(
      'SELECT status FROM studio_work_orders WHERE order_id = ?',
      variables: [Variable(orderId)],
    ).get();
    if (rows.isEmpty) return;
    final statuses = rows.map((row) => row.read<String>('status')).toList();
    final allCompleted = statuses.every((status) => status == 'completed');
    final anyProduction = statuses.any(
      (status) => status != 'completed' && status != 'cancelled',
    );
    final next = allCompleted
        ? StudioOrderStatus.completed
        : anyProduction
        ? StudioOrderStatus.production
        : null;
    if (next != null) {
      await customUpdate(
        'UPDATE studio_orders SET status = ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable(next.name),
          Variable(DateTime.now().millisecondsSinceEpoch),
          Variable(orderId),
        ],
      );
    }
  }

  Future<void> _reconcileInventoryBatchTotals(String workspaceId) async {
    await customUpdate(
      '''
      INSERT OR IGNORE INTO studio_inventory_batch_items(
        id, batch_id, consumable_id, roll_count, grams_per_roll,
        unit_cost, created_at, updated_at
      )
      SELECT
        'sync-' || batch.id || '-' || consumable.id,
        batch.id,
        consumable.id,
        MAX(1, CAST(ROUND(consumable.total_grams / $_farmRollGrams) AS INTEGER)),
        $_farmRollGrams,
        0,
        batch.created_at,
        batch.created_at
      FROM studio_inventory_batches batch
      JOIN consumables consumable
        ON consumable.farm_workspace_id = batch.workspace_id
       AND consumable.inventory_scope = 'farm'
       AND trim(COALESCE(consumable.batch_no, '')) = trim(batch.batch_no)
      WHERE batch.workspace_id = ? AND trim(batch.batch_no) != ''
      ''',
      variables: [Variable(workspaceId)],
    );
    await customUpdate(
      '''
      UPDATE studio_inventory_batch_items
      SET roll_count = (
            SELECT MAX(
              1,
              CAST(ROUND(consumable.total_grams / $_farmRollGrams) AS INTEGER)
            )
            FROM consumables consumable
            WHERE consumable.id = studio_inventory_batch_items.consumable_id
          ),
          grams_per_roll = $_farmRollGrams
       WHERE voided = 0 AND batch_id IN (
        SELECT id FROM studio_inventory_batches WHERE workspace_id = ?
      )
      ''',
      variables: [Variable(workspaceId)],
    );
    await customUpdate(
      '''
      UPDATE studio_inventory_batches
      SET roll_count = (
            SELECT COALESCE(SUM(item.roll_count), 0)
            FROM studio_inventory_batch_items item
            WHERE item.batch_id = studio_inventory_batches.id AND item.voided = 0
          ),
          total_grams = (
            SELECT COALESCE(SUM(consumable.total_grams), 0)
            FROM studio_inventory_batch_items item
            JOIN consumables consumable ON consumable.id = item.consumable_id
            WHERE item.batch_id = studio_inventory_batches.id AND item.voided = 0
          )
       WHERE workspace_id = ? AND EXISTS(
         SELECT 1 FROM studio_inventory_batch_items item
         WHERE item.batch_id = studio_inventory_batches.id AND item.voided = 0
       )
      ''',
      variables: [Variable(workspaceId)],
    );
  }

  Future<StudioSnapshot> _fetchSnapshot(String workspaceId) async {
    final workspaceRow = await customSelect(
      'SELECT * FROM studio_workspaces WHERE id = ?',
      variables: [Variable(workspaceId)],
    ).getSingle();
    final results = await Future.wait([
      customSelect(
        'SELECT * FROM studio_members WHERE workspace_id = ? ORDER BY active DESC, role ASC, created_at ASC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_customers WHERE workspace_id = ? ORDER BY archived ASC, updated_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_orders WHERE workspace_id = ? ORDER BY created_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_work_orders WHERE workspace_id = ? ORDER BY created_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_quotes WHERE workspace_id = ? ORDER BY created_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_inventory_events WHERE workspace_id = ? ORDER BY created_at DESC LIMIT 200',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_share_links WHERE workspace_id = ? ORDER BY created_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_inventory_batches WHERE workspace_id = ? ORDER BY received_at DESC LIMIT 100',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_production_packages WHERE workspace_id = ? ORDER BY created_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_production_plates WHERE workspace_id = ? ORDER BY plate_index ASC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_order_items WHERE workspace_id = ? ORDER BY created_at ASC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_work_order_materials WHERE workspace_id = ? '
        'ORDER BY work_order_id, tool_index ASC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT item.* FROM studio_inventory_batch_items item '
        'JOIN studio_inventory_batches batch ON batch.id = item.batch_id '
        'WHERE batch.workspace_id = ? ORDER BY item.created_at ASC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_print_attempts WHERE workspace_id = ? '
        'ORDER BY ended_at DESC',
        variables: [Variable(workspaceId)],
      ).get(),
      customSelect(
        'SELECT * FROM studio_activity_events WHERE workspace_id = ? '
        'ORDER BY created_at DESC LIMIT 500',
        variables: [Variable(workspaceId)],
      ).get(),
    ]);
    return StudioSnapshot(
      workspace: _workspace(workspaceRow),
      members: results[0].map(_member).toList(),
      customers: results[1].map(_customer).toList(),
      orders: results[2].map(_order).toList(),
      workOrders: results[3].map(_workOrder).toList(),
      quotes: results[4].map(_quote).toList(),
      inventoryEvents: results[5].map(_inventoryEvent).toList(),
      shareLinks: results[6].map(_shareLink).toList(),
      inventoryBatches: results[7].map(_inventoryBatch).toList(),
      productionPackages: results[8].map(_productionPackage).toList(),
      productionPlates: results[9].map(_productionPlate).toList(),
      orderItems: results[10].map(_orderItem).toList(),
      workOrderMaterials: results[11].map(_workOrderMaterial).toList(),
      inventoryBatchItems: results[12].map(_inventoryBatchItem).toList(),
      printAttempts: results[13].map(_printAttempt).toList(),
      activityEvents: results[14].map(_activityEvent).toList(),
    );
  }

  Future<List<StudioActivityEvent>> _fetchAllActivityEvents(
    String workspaceId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM studio_activity_events WHERE workspace_id = ? '
      'ORDER BY created_at DESC',
      variables: [Variable(workspaceId)],
    ).get();
    return rows.map(_activityEvent).toList(growable: false);
  }

  StudioWorkspace _workspace(QueryRow row) => StudioWorkspace(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    remoteId: row.read<String?>('remote_id'),
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioMember _member(QueryRow row) => StudioMember(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    displayName: row.read<String>('display_name'),
    email: row.read<String?>('email'),
    loginName: row.read<String?>('login_name'),
    employeeNo: row.read<String?>('employee_no'),
    phone: row.read<String?>('phone'),
    recoveryEmail: row.read<String?>('recovery_email'),
    accountStatus: row.read<String>('account_status'),
    primaryRoleCode: row.read<String>('role') == 'owner' ? 'owner' : 'member',
    roleCodes: row.read<String>('role') == 'owner'
        ? const ['owner']
        : const ['member'],
    mustChangePassword: row.read<int>('must_change_password') == 1,
    lastLoginAt: _nullableDate(row.read<int?>('last_login_at')),
    deactivatedAt: _nullableDate(row.read<int?>('deactivated_at')),
    role: StudioMemberRole.fromCode(row.read<String>('role')),
    active: row.read<int>('active') == 1,
    createdAt: _date(row.read<int>('created_at')),
  );

  StudioActivityEvent _activityEvent(QueryRow row) => StudioActivityEvent(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    actorMemberId: row.read<String?>('actor_member_id'),
    actorDisplayName: row.read<String>('actor_display_name'),
    actorIdentity: row.read<String>('actor_identity'),
    actionCode: row.read<String>('action_code'),
    entityType: row.read<String>('entity_type'),
    entityId: row.read<String>('entity_id'),
    summary: row.read<String>('summary'),
    createdAt: _date(row.read<int>('created_at')),
  );

  StudioCustomer _customer(QueryRow row) => StudioCustomer(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    name: row.read<String>('name'),
    contactName: row.read<String?>('contact_name'),
    phone: row.read<String?>('phone'),
    email: row.read<String?>('email'),
    note: row.read<String?>('note'),
    archived: row.read<int>('archived') == 1,
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioOrder _order(QueryRow row) => StudioOrder(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    customerId: row.read<String?>('customer_id'),
    orderNo: row.read<String>('order_no'),
    title: row.read<String>('title'),
    status: StudioOrderStatus.fromCode(row.read<String>('status')),
    dueAt: _nullableDate(row.read<int?>('due_at')),
    totalPrice: row.read<double>('total_price'),
    note: row.read<String?>('note'),
    publicNote: row.read<String?>('public_note'),
    portalVideoEnabled: row.read<int>('portal_video_enabled') == 1,
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioWorkOrder _workOrder(QueryRow row) => StudioWorkOrder(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    orderId: row.read<String>('order_id'),
    schedulerTaskId: row.read<int?>('scheduler_task_id'),
    productionPlateId: row.read<String?>('production_plate_id'),
    title: row.read<String>('title'),
    quantity: row.read<int>('quantity'),
    completedQuantity: row.read<int>('completed_quantity'),
    status: StudioWorkOrderStatus.fromCode(row.read<String>('status')),
    assignedMemberId: row.read<String?>('assigned_member_id'),
    printerId: row.read<int?>('printer_id'),
    estimatedSeconds: row.read<int?>('estimated_seconds'),
    materialCostSnapshot: row.read<double>('material_cost_snapshot'),
    quotedPriceSnapshot: row.read<double>('quoted_price_snapshot'),
    note: row.read<String?>('note'),
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioProductionPackage _productionPackage(QueryRow row) =>
      StudioProductionPackage(
        id: row.read<String>('id'),
        workspaceId: row.read<String>('workspace_id'),
        orderId: row.read<String>('order_id'),
        sourceName: row.read<String>('source_name'),
        localPath: row.read<String?>('local_path'),
        artifactSha256: row.read<String?>('artifact_sha256'),
        artifactKind: row.read<String>('artifact_kind'),
        slicerName: row.read<String?>('slicer_name'),
        slicerVersion: row.read<String?>('slicer_version'),
        targetModel: row.read<String?>('target_model'),
        nozzleDiameter: row.read<double?>('nozzle_diameter'),
        createdAt: _date(row.read<int>('created_at')),
      );

  StudioProductionPlate _productionPlate(QueryRow row) => StudioProductionPlate(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    orderId: row.read<String>('order_id'),
    packageId: row.read<String>('package_id'),
    plateIndex: row.read<int>('plate_index'),
    name: row.read<String>('name'),
    requiredRuns: row.read<int>('required_runs'),
    estimatedSeconds: row.read<int>('estimated_seconds'),
    estimatedGrams: row.read<double>('estimated_grams'),
    sliceStatus: StudioPlateSliceStatus.fromCode(
      row.read<String>('slice_status'),
    ),
    sliceArtifactPath: row.read<String?>('slice_artifact_path'),
    sliceArtifactSha256: row.read<String?>('slice_artifact_sha256'),
    sliceTargetModel: row.read<String?>('slice_target_model'),
    sliceNozzleDiameter: row.read<double?>('slice_nozzle_diameter'),
    autoEjectEnabled: switch (row.read<int?>('auto_eject_enabled')) {
      1 => true,
      0 => false,
      _ => null,
    },
    thumbnailBytes: _decodeStudioThumbnail(
      row.read<String>('id'),
      row.read<String?>('thumbnail_base64'),
    ),
    totalLayers: row.read<int>('total_layers'),
    toolChangeCount: row.read<int>('tool_change_count'),
    filaments: _decodeFilaments(row.read<String>('filament_usage_json')),
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioOrderItem _orderItem(QueryRow row) => StudioOrderItem(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    orderId: row.read<String>('order_id'),
    packageId: row.read<String>('package_id'),
    plateId: row.read<String>('plate_id'),
    sourceKey: row.read<String>('source_key'),
    name: row.read<String>('name'),
    perRunQuantity: row.read<int>('per_run_quantity'),
    requiredQuantity: row.read<int>('required_quantity'),
    createdAt: _date(row.read<int>('created_at')),
  );

  StudioWorkOrderMaterial _workOrderMaterial(QueryRow row) =>
      StudioWorkOrderMaterial(
        id: row.read<String>('id'),
        workspaceId: row.read<String>('workspace_id'),
        workOrderId: row.read<String>('work_order_id'),
        productionPlateId: row.read<String>('production_plate_id'),
        toolIndex: row.read<int>('tool_index'),
        materialType: row.read<String?>('material_type'),
        colorHex: row.read<String?>('color_hex'),
        sku: row.read<String?>('sku'),
        estimatedGrams: row.read<double>('estimated_grams'),
        consumableId: row.read<int?>('consumable_id'),
        printerChannelId: row.read<int?>('printer_channel_id'),
        reservedGrams: row.read<double>('reserved_grams'),
        consumedGrams: row.read<double>('consumed_grams'),
        status: StudioWorkOrderMaterialStatus.fromCode(
          row.read<String>('status'),
        ),
        createdAt: _date(row.read<int>('created_at')),
        updatedAt: _date(row.read<int>('updated_at')),
        settledAt: _nullableDate(row.read<int?>('settled_at')),
      );

  StudioPrintAttempt _printAttempt(QueryRow row) => StudioPrintAttempt(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    workOrderId: row.read<String>('work_order_id'),
    printQueueId: row.read<int?>('print_queue_id'),
    attemptNo: row.read<int>('attempt_no'),
    printerSerial: row.read<String?>('printer_serial'),
    outcome: StudioPrintAttemptOutcome.fromCode(row.read<String>('outcome')),
    progressPercent: row.read<int?>('progress_percent'),
    consumedGrams: row.read<double>('consumed_grams'),
    materialCost: row.read<double>('material_cost'),
    failureReason: row.read<String?>('failure_reason'),
    errorCode: row.read<String?>('error_code'),
    startedAt: _nullableDate(row.read<int?>('started_at')),
    endedAt: _date(row.read<int>('ended_at')),
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioQuote _quote(QueryRow row) => StudioQuote(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    customerId: row.read<String?>('customer_id'),
    orderId: row.read<String?>('order_id'),
    costConfigId: row.read<int?>('cost_config_id'),
    quoteNo: row.read<String>('quote_no'),
    title: row.read<String>('title'),
    status: StudioQuoteStatus.fromCode(row.read<String>('status')),
    materialLabel: row.read<String>('material_label'),
    estimatedGrams: row.read<double>('estimated_grams'),
    materialCostPerKgSnapshot: row.read<double>(
      'material_cost_per_kg_snapshot',
    ),
    machineHours: row.read<double>('machine_hours'),
    machineRatePerHour: row.read<double>('machine_rate_per_hour'),
    laborHours: row.read<double>('labor_hours'),
    laborRatePerHour: row.read<double>('labor_rate_per_hour'),
    electricityCost: row.read<double>('electricity_cost'),
    packagingCost: row.read<double>('packaging_cost'),
    riskPercent: row.read<double>('risk_percent'),
    markupPercent: row.read<double>('markup_percent'),
    totalCost: row.read<double>('total_cost'),
    quotedPrice: row.read<double>('quoted_price'),
    note: row.read<String?>('note'),
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioInventoryEvent _inventoryEvent(QueryRow row) => StudioInventoryEvent(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    consumableId: row.read<int>('consumable_id'),
    type: StudioInventoryEventType.fromCode(row.read<String>('event_type')),
    deltaGrams: row.read<double>('delta_grams'),
    reason: row.read<String>('reason'),
    memberId: row.read<String?>('member_id'),
    createdAt: _date(row.read<int>('created_at')),
  );

  StudioShareLink _shareLink(QueryRow row) => StudioShareLink(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    orderId: row.read<String>('order_id'),
    tokenPreview: row.read<String>('token_preview'),
    publicUrl: row.read<String?>('public_url'),
    active: row.read<int>('active') == 1,
    expiresAt: _nullableDate(row.read<int?>('expires_at')),
    passwordRequired: row.read<int>('password_required') == 1,
    createdAt: _date(row.read<int>('created_at')),
  );

  StudioInventoryBatch _inventoryBatch(QueryRow row) => StudioInventoryBatch(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('workspace_id'),
    batchNo: row.read<String>('batch_no'),
    supplier: row.read<String?>('supplier'),
    receivedAt: _date(row.read<int>('received_at')),
    rollCount: row.read<int>('roll_count'),
    totalGrams: row.read<double>('total_grams'),
    note: row.read<String?>('note'),
    memberId: row.read<String?>('member_id'),
    createdAt: _date(row.read<int>('created_at')),
    updatedAt: _date(row.read<int>('updated_at')),
  );

  StudioInventoryBatchItem _inventoryBatchItem(QueryRow row) =>
      StudioInventoryBatchItem(
        id: row.read<String>('id'),
        batchId: row.read<String>('batch_id'),
        consumableId: row.read<int>('consumable_id'),
        rollCount: row.read<int>('roll_count'),
        gramsPerRoll: row.read<double>('grams_per_roll'),
        unitCost: row.read<double>('unit_cost'),
        voided: row.read<int>('voided') == 1,
        voidReason: row.read<String?>('void_reason'),
        voidedAt: _nullableDate(row.read<int?>('voided_at')),
        createdAt: _date(row.read<int>('created_at')),
        updatedAt: _date(row.read<int>('updated_at')),
      );

  String _encodeFilaments(List<StudioPlateFilamentUsage> filaments) =>
      jsonEncode([
        for (final item in filaments)
          {
            'toolIndex': item.toolIndex,
            'grams': item.grams,
            'vendor': item.vendor,
            'materialType': item.materialType,
            'colorHex': item.colorHex,
            'trayId': item.trayId,
            'sku': item.sku,
            'usedForObject': item.usedForObject,
            'usedForSupport': item.usedForSupport,
            'groupId': item.groupId,
            'nozzleDiameter': item.nozzleDiameter,
            'volumeType': item.volumeType,
          },
      ]);

  String _encodeRemoteFilaments(Object? value) {
    final parsed = _maps(value)
        .map((item) {
          return StudioPlateFilamentUsage(
            toolIndex: math.max(0, _integer(item['toolIndex'])),
            grams: math.max(0, _number(item['grams'])),
            vendor: _text(item['vendor']),
            materialType: _text(item['materialType']),
            colorHex: _text(item['colorHex']),
            trayId: item['trayId'] == null ? null : _integer(item['trayId']),
            sku: _text(item['sku']),
            usedForObject: _boolean(item['usedForObject']),
            usedForSupport: _boolean(item['usedForSupport']),
            groupId: item['groupId'] == null ? null : _integer(item['groupId']),
            nozzleDiameter: item['nozzleDiameter'] == null
                ? null
                : _number(item['nozzleDiameter']),
            volumeType: _text(item['volumeType']),
          );
        })
        .toList(growable: false);
    return _encodeFilaments(parsed);
  }

  List<StudioPlateFilamentUsage> _decodeFilaments(String value) {
    try {
      final decoded = jsonDecode(value);
      return _maps(decoded)
          .map((item) {
            return StudioPlateFilamentUsage(
              toolIndex: math.max(0, _integer(item['toolIndex'])),
              grams: math.max(0, _number(item['grams'])),
              vendor: _text(item['vendor']),
              materialType: _text(item['materialType']),
              colorHex: _text(item['colorHex']),
              trayId: item['trayId'] == null ? null : _integer(item['trayId']),
              sku: _text(item['sku']),
              usedForObject: _boolean(item['usedForObject']),
              usedForSupport: _boolean(item['usedForSupport']),
              groupId: item['groupId'] == null
                  ? null
                  : _integer(item['groupId']),
              nozzleDiameter: item['nozzleDiameter'] == null
                  ? null
                  : _number(item['nozzleDiameter']),
              volumeType: _text(item['volumeType']),
            );
          })
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _refreshPlateMaterialRequirements({
    required String productionPlateId,
    required double estimatedGrams,
    required List<StudioPlateFilamentUsage> filaments,
    required int now,
  }) async {
    final workOrders = await customSelect(
      'SELECT id, workspace_id, quantity, status FROM studio_work_orders '
      'WHERE production_plate_id = ? AND printer_id IS NULL',
      variables: [Variable(productionPlateId)],
    ).get();
    for (final row in workOrders) {
      final status = StudioWorkOrderStatus.fromCode(row.read<String>('status'));
      if (status == StudioWorkOrderStatus.completed ||
          status == StudioWorkOrderStatus.cancelled ||
          status == StudioWorkOrderStatus.failed) {
        continue;
      }
      await _replaceWorkOrderMaterialRequirements(
        workspaceId: row.read<String>('workspace_id'),
        workOrderId: row.read<String>('id'),
        productionPlateId: productionPlateId,
        quantity: row.read<int>('quantity'),
        estimatedGrams: estimatedGrams,
        filaments: filaments,
        now: now,
      );
    }
  }

  Future<void> _replaceWorkOrderMaterialRequirements({
    required String workspaceId,
    required String workOrderId,
    required String productionPlateId,
    required int quantity,
    required double estimatedGrams,
    required List<StudioPlateFilamentUsage> filaments,
    required int now,
  }) async {
    final removed = await customSelect(
      'SELECT id FROM studio_work_order_materials WHERE work_order_id = ? '
      "AND status != 'settled'",
      variables: [Variable(workOrderId)],
    ).get();
    await customUpdate(
      'DELETE FROM studio_work_order_materials WHERE work_order_id = ? '
      "AND status != 'settled'",
      variables: [Variable(workOrderId)],
    );
    for (final row in removed) {
      await customInsert(
        'INSERT INTO studio_sync_tombstones '
        '(workspace_id, entity_type, entity_id, deleted_at) '
        "VALUES (?, 'workOrderMaterial', ?, ?) "
        'ON CONFLICT(workspace_id, entity_type, entity_id) DO UPDATE SET '
        'deleted_at = MAX(deleted_at, excluded.deleted_at)',
        variables: [
          Variable(workspaceId),
          Variable(row.read<String>('id')),
          Variable(now),
        ],
      );
    }
    final active = StudioPlateFilamentUsage.activeByTool(filaments);
    final requirements = active.isNotEmpty
        ? active
        : estimatedGrams > 0.01
        ? [StudioPlateFilamentUsage(toolIndex: 0, grams: estimatedGrams)]
        : const <StudioPlateFilamentUsage>[];
    for (final filament in requirements) {
      await customInsert(
        'INSERT INTO studio_work_order_materials '
        '(id, workspace_id, work_order_id, production_plate_id, tool_index, '
        'material_type, color_hex, sku, estimated_grams, consumable_id, '
        'reserved_grams, consumed_grams, status, created_at, updated_at) '
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, 0, 'unallocated', ?, ?)",
        variables: [
          Variable(_uuid.v4()),
          Variable(workspaceId),
          Variable(workOrderId),
          Variable(productionPlateId),
          Variable(filament.toolIndex),
          Variable(_nullable(filament.materialType)),
          Variable(_normalizedColor(filament.colorHex)),
          Variable(_nullable(filament.sku)),
          Variable(math.max(0, filament.grams) * math.max(1, quantity)),
          Variable(now),
          Variable(now),
        ],
      );
    }
  }

  Future<StudioConsumableAvailability> _getConsumableAvailability(
    int consumableId, {
    required String workspaceId,
    String? excludingWorkOrderId,
  }) async {
    Future<double> scalar(String sql, List<Variable> variables) async {
      final row = await customSelect(
        sql,
        variables: variables,
      ).getSingleOrNull();
      return (row?.data.values.first as num?)?.toDouble() ?? 0;
    }

    final stock = await scalar(
      'SELECT COALESCE(remaining_grams, 0) FROM consumables WHERE id = ? '
      'AND ${_inventoryWhere(workspaceId)}',
      [Variable(consumableId), ..._inventoryVariables(workspaceId)],
    );
    final scheduler = await scalar(
      'SELECT COALESCE(SUM(reserved_grams), 0) FROM spool_reservations '
      "WHERE consumable_id = ? AND status = 'active'",
      [Variable(consumableId)],
    );
    final printTasks = await scalar(
      'SELECT COALESCE(SUM(CASE WHEN estimated_grams > last_deducted_grams '
      'THEN estimated_grams - last_deducted_grams ELSE 0 END), 0) '
      'FROM print_task_consumables '
      'WHERE consumable_id = ? AND consumed_at IS NULL',
      [Variable(consumableId)],
    );
    final studio = await scalar(
      'SELECT COALESCE(SUM(reserved_grams), 0) '
      'FROM studio_work_order_materials '
      "WHERE consumable_id = ? AND status = 'reserved' "
      '${excludingWorkOrderId == null ? '' : 'AND work_order_id <> ?'}',
      [
        Variable(consumableId),
        if (excludingWorkOrderId != null) Variable(excludingWorkOrderId),
      ],
    );
    return StudioConsumableAvailability(
      remainingGrams: stock,
      schedulerReservedGrams: scheduler,
      printTaskReservedGrams: printTasks,
      studioReservedGrams: studio,
    );
  }

  Future<double> _farmMaterialCostPerGram(int consumableId) async {
    final batchCost = await customSelect(
      'SELECT unit_cost, grams_per_roll FROM studio_inventory_batch_items '
      'WHERE consumable_id = ? ORDER BY created_at DESC LIMIT 1',
      variables: [Variable(consumableId)],
    ).getSingleOrNull();
    if (batchCost != null) {
      final grams = batchCost.read<double>('grams_per_roll');
      if (grams > 0) {
        return math.max(0, batchCost.read<double>('unit_cost')) / grams;
      }
    }

    final configured = await customSelect(
      'SELECT config.cost_per_kg FROM consumables stock '
      'JOIN filament_cost_configs config '
      'ON upper(trim(config.material_type)) = '
      'upper(trim(stock.material_type)) '
      "AND (trim(config.vendor) = '' OR upper(trim(config.vendor)) = "
      'upper(trim(stock.manufacturer))) '
      "AND (trim(config.color_hex) = '' OR upper(trim(config.color_hex)) = "
      'upper(trim(stock.color_hex))) '
      'WHERE stock.id = ? '
      "ORDER BY CASE WHEN trim(config.vendor) = '' THEN 1 ELSE 0 END, "
      "CASE WHEN trim(config.color_hex) = '' THEN 1 ELSE 0 END "
      'LIMIT 1',
      variables: [Variable(consumableId)],
    ).getSingleOrNull();
    return math.max(0, configured?.read<double>('cost_per_kg') ?? 0) / 1000;
  }

  String? _normalizedColor(String? value) {
    final raw = _nullable(value)?.toUpperCase();
    if (raw == null) return null;
    final normalized = raw.startsWith('#') ? raw : '#$raw';
    return normalized.length == 9
        ? '#${normalized.substring(normalized.length - 6)}'
        : normalized;
  }

  DateTime _date(int value) => DateTime.fromMillisecondsSinceEpoch(value);
  DateTime? _nullableDate(int? value) => value == null ? null : _date(value);
  String? _nullable(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  List<Map<String, dynamic>> _maps(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }

  String? _text(Object? value) {
    final result = value?.toString().trim();
    return result == null || result.isEmpty ? null : result;
  }

  double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool? _boolean(Object? value) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
    return null;
  }

  int _integer(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _remoteDate(Object? value, {int? fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed?.millisecondsSinceEpoch ??
        fallback ??
        DateTime.now().millisecondsSinceEpoch;
  }

  int? _remoteNullableDate(Object? value) {
    if (value == null) return null;
    return _remoteDate(value);
  }

  int _driftNowSeconds() => _driftDateSeconds(DateTime.now());

  int _driftDateSeconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;

  int _normalizeDriftEpochSeconds(int value) {
    var normalized = value;
    while (normalized.abs() >= 100000000000) {
      normalized ~/= 1000;
    }
    return normalized;
  }

  int _remoteDriftDate(Object? value, {int? fallback}) {
    if (value is int) return _normalizeDriftEpochSeconds(value);
    if (value is num) return _normalizeDriftEpochSeconds(value.toInt());
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed != null) return _driftDateSeconds(parsed);
    return fallback ?? _driftNowSeconds();
  }

  int? _remoteNullableDriftDate(Object? value) {
    if (value == null) return null;
    return _remoteDriftDate(value);
  }

  void dispose() => _changes.close();
}
