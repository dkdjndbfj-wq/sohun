import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/database/database.dart';
import '../data/database/daos/studio_dao.dart';
import '../data/database/models/studio_quote_config_models.dart';
import '../data/external/community/studio_api_client.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/prefs/app_prefs.dart';
import '../core/services/printer_fleet_connection_manager.dart';
import 'app_auth_provider.dart';
import 'database_provider.dart';

final studioDaoProvider = Provider<StudioDao>((ref) {
  final auth = ref.watch(appAuthProvider);
  final farmMode = ref.watch(studioModeEnabledProvider);
  final session = auth.session;
  final isStaff = session?.authRealm == 'farm_staff';
  final actor = StudioActivityActor(
    memberId: isStaff ? session?.farmStaffMemberId : null,
    displayName: auth.user?.displayName.trim().isNotEmpty == true
        ? auth.user!.displayName.trim()
        : session?.farmStaffLoginName ?? '管理员',
    identity: isStaff ? 'member' : 'administrator',
  );
  final accountScope = session == null
      ? null
      : farmMode
          ? (isStaff && session.farmOrganizationId != null
              ? '${session.serverBaseUrl}|farm:${session.farmOrganizationId}'
              : '${session.serverBaseUrl}|farm-owner:${session.user.id}')
          : '${session.serverBaseUrl}|account:${session.user.id}';
  final dao = StudioDao(
    ref.watch(databaseProvider),
    actor: actor,
    accountScope: accountScope,
    remoteWorkspaceId: farmMode && isStaff ? session?.farmOrganizationId : null,
    farmInventory: farmMode,
  );
  ref.onDispose(dao.dispose);
  return dao;
});

final studioSnapshotProvider = StreamProvider<StudioSnapshot>((ref) {
  return ref.watch(studioDaoProvider).watchDefaultSnapshot();
});

final studioQuoteSettingsProvider =
    StreamProvider<StudioQuoteSettings>((ref) async* {
  final workspace = (await ref.watch(studioSnapshotProvider.future)).workspace;
  yield* ref.watch(studioQuoteConfigDaoProvider).watchSettings(workspace.id);
});

final studioMachineCostConfigsProvider =
    StreamProvider<List<StudioMachineCostConfig>>((ref) async* {
  final workspace = (await ref.watch(studioSnapshotProvider.future)).workspace;
  yield* ref.watch(studioQuoteConfigDaoProvider).watchMachines(workspace.id);
});

final studioActivityEventsProvider =
    StreamProvider<List<StudioActivityEvent>>((ref) {
  return ref.watch(studioDaoProvider).watchAllActivityEvents();
});

Future<void> recordCurrentFarmActivity(
  WidgetRef ref, {
  required String actionCode,
  required String entityType,
  required String entityId,
  required String summary,
}) async {
  final dao = ref.read(studioDaoProvider);
  final workspace = (await dao.getDefaultSnapshot()).workspace;
  await dao.recordActivity(
    workspaceId: workspace.id,
    actionCode: actionCode,
    entityType: entityType,
    entityId: entityId,
    summary: summary,
  );
}

final farmConsumablesProvider = StreamProvider<List<Consumable>>((ref) async* {
  final dao = ref.watch(consumableDaoProvider);
  final snapshot = await ref.watch(studioSnapshotProvider.future);
  yield* dao.watchFarm(snapshot.workspace.id);
});

final currentStudioRoleProvider = Provider<StudioMemberRole>((ref) {
  final snapshot = ref.watch(studioSnapshotProvider).valueOrNull;
  if (snapshot == null) return StudioMemberRole.operator;
  final authSession =
      ref.watch(appAuthProvider.select((state) => state.session));
  if (authSession?.authRealm == 'farm_staff') {
    final member = snapshot.members
        .where(
          (item) =>
              item.active &&
              (item.id == authSession?.farmStaffMemberId ||
                  item.loginName == authSession?.farmStaffLoginName),
        )
        .firstOrNull;
    if (member != null) return member.role;
  }
  final authEmail = ref.watch(
    appAuthProvider.select((state) => state.user?.email.toLowerCase()),
  );
  if (authEmail != null) {
    final member = snapshot.members
        .where(
          (item) => item.email?.toLowerCase() == authEmail && item.active,
        )
        .firstOrNull;
    if (member != null) return member.role;
  }
  return snapshot.workspace.remoteId == null
      ? StudioMemberRole.owner
      : StudioMemberRole.operator;
});

final currentFarmRoleCodesProvider = Provider<Set<String>>((ref) {
  final session = ref.watch(appAuthProvider.select((state) => state.session));
  if (session == null) return const <String>{};
  return session.authRealm == 'farm_staff'
      ? const {'member'}
      : const {'administrator'};
});

final currentFarmIsOwnerProvider = Provider<bool>((ref) {
  return ref.watch(currentFarmRoleCodesProvider).contains('administrator');
});

final farmAuditLogsProvider =
    FutureProvider.autoDispose<List<StudioRemoteAuditLog>>((ref) async {
  if (!ref.watch(currentFarmIsOwnerProvider)) return const [];
  return ref.read(studioCloudServiceProvider).getFarmAuditLogs();
});

/// 农场不再按岗位拆权限。管理员和成员都可使用全部日常农场功能，
/// 数据由同一工作区同步；服务端仍校验账号是否属于该农场且处于启用状态。
final currentFarmPermissionProvider =
    Provider.family<bool, String>((ref, code) {
  final roles = ref.watch(currentFarmRoleCodesProvider);
  return roles.isNotEmpty;
});

enum StudioSyncPhase { disabled, localOnly, syncing, synced, error }

class StudioSyncState {
  const StudioSyncState({
    required this.phase,
    this.lastSyncedAt,
    this.message,
  });

  const StudioSyncState.disabled() : this(phase: StudioSyncPhase.disabled);

  final StudioSyncPhase phase;
  final DateTime? lastSyncedAt;
  final String? message;

  bool get isSyncing => phase == StudioSyncPhase.syncing;
}

class StudioCloudService {
  StudioCloudService(this.ref);

  final Ref ref;

  Future<void> sync() async {
    final auth = ref.read(appAuthProvider);
    final endpoint = auth.endpoint;
    if (endpoint == null || !auth.isSignedIn) {
      throw const StudioCloudException('请先在设置中配置并登录 sohun 云服务');
    }
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final api = StudioApiClient(
      baseUri: endpoint,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final dao = ref.read(studioDaoProvider);
    final workspaces = await api.listWorkspaces(session.accessToken);
    var local = await dao.getDefaultSnapshot();
    Map<String, dynamic>? remoteWorkspace;
    final organizationId = session.farmOrganizationId;
    if (session.authRealm == 'farm_staff' && organizationId != null) {
      remoteWorkspace =
          workspaces.where((item) => item['id'] == organizationId).firstOrNull;
    }
    final remoteId = local.workspace.remoteId;
    if (remoteWorkspace == null && remoteId != null) {
      remoteWorkspace =
          workspaces.where((item) => item['id'] == remoteId).firstOrNull;
    }
    remoteWorkspace ??= workspaces
        .where((item) => item['id'] == local.workspace.id)
        .firstOrNull;
    // A staff account attaches to its assigned organization. A main account
    // must attach to an organization it actually owns, never an invitation.
    remoteWorkspace ??= session.authRealm == 'farm_staff'
        ? null
        : workspaces.where((item) => item['role'] == 'owner').firstOrNull;
    if (remoteWorkspace == null) {
      throw const StudioCloudException(
        '当前软件账号尚未开通农场管理员身份，请先提交申请或切换到成员账号',
        code: 'farm_workspace_not_registered',
        statusCode: 404,
      );
    }
    final remoteWorkspaceId = remoteWorkspace['id'] as String;
    await dao.bindRemoteWorkspace(
      remoteWorkspaceId,
      accountScope: '${session.serverBaseUrl}|farm:$remoteWorkspaceId',
      name: remoteWorkspace['name'] as String?,
    );
    local = await dao.getDefaultSnapshot();

    var remote = await api.getSnapshot(
      accessToken: session.accessToken,
      workspaceId: remoteWorkspaceId,
    );
    final currentRole = (remoteWorkspace['role'] as String?) ?? 'owner';
    var membersChanged = false;
    if (currentRole == 'owner' || currentRole == 'admin') {
      for (final member in local.members) {
        final email = member.email?.trim();
        if (email == null ||
            email.isEmpty ||
            member.role == StudioMemberRole.owner) {
          continue;
        }
        if (currentRole == 'admin' &&
            member.role != StudioMemberRole.operator) {
          continue;
        }
        final remoteMember = remote.members
            .where(
              (item) =>
                  (item['email'] as String?)?.toLowerCase() ==
                  email.toLowerCase(),
            )
            .firstOrNull;
        if (member.active) {
          final unchanged = remoteMember != null &&
              remoteMember['active'] != false &&
              remoteMember['role'] == member.role.name &&
              remoteMember['displayName'] == member.displayName;
          if (unchanged) continue;
          await api.upsertMember(
            accessToken: session.accessToken,
            workspaceId: remoteWorkspaceId,
            email: email,
            displayName: member.displayName,
            role: member.role.name,
          );
          membersChanged = true;
        } else if (remoteMember != null && remoteMember['active'] != false) {
          final remoteRole = remoteMember['role'] as String? ?? 'operator';
          if (currentRole == 'owner' || remoteRole == 'operator') {
            await api.deactivateMember(
              accessToken: session.accessToken,
              workspaceId: remoteWorkspaceId,
              memberId: remoteMember['id'] as String,
            );
            membersChanged = true;
          }
        }
      }
    }
    if (membersChanged) {
      remote = await api.getSnapshot(
        accessToken: session.accessToken,
        workspaceId: remoteWorkspaceId,
      );
    }
    await dao.mergeRemoteSnapshot(remote.snapshot, notify: false);
    await dao.mergeRemoteMembers(remote.members, notify: false);
    await dao.mergeRemoteShareLinks(remote.shareLinks, notify: false);
    ref.invalidate(studioSnapshotProvider);
    ref.invalidate(studioActivityEventsProvider);

    local = await dao.getDefaultSnapshot();

    // 管理员和成员共用同一份农场数据。所有身份都把带操作者署名的变更写回
    // 同一修订快照，服务端仍通过 workspace.snapshot.write 校验成员有效性。

    final payload = await _serialize(local);
    try {
      await api.putSnapshot(
        accessToken: session.accessToken,
        workspaceId: remoteWorkspaceId,
        baseRevision: remote.revision,
        snapshot: payload,
      );
    } on StudioCloudException catch (error) {
      if (!error.isConflict) rethrow;
      remote = await api.getSnapshot(
        accessToken: session.accessToken,
        workspaceId: remoteWorkspaceId,
      );
      await dao.mergeRemoteSnapshot(remote.snapshot, notify: false);
      await dao.mergeRemoteMembers(remote.members, notify: false);
      await dao.mergeRemoteShareLinks(remote.shareLinks, notify: false);
      ref.invalidate(studioSnapshotProvider);
      ref.invalidate(studioActivityEventsProvider);
      local = await dao.getDefaultSnapshot();
      await api.putSnapshot(
        accessToken: session.accessToken,
        workspaceId: remoteWorkspaceId,
        baseRevision: remote.revision,
        snapshot: await _serialize(local),
      );
    }
  }

  Future<bool> hasOwnedFarmOrganization() async {
    final auth = ref.read(appAuthProvider);
    if (!auth.isSignedIn || auth.endpoint == null) return false;
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    if (session.authRealm == 'farm_staff') return false;
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final workspaces = await api.listWorkspaces(session.accessToken);
    return workspaces.any((item) => item['role'] == 'owner');
  }

  Future<void> registerFarmOrganization() async {
    final auth = ref.read(appAuthProvider);
    if (!auth.isSignedIn || auth.endpoint == null) {
      throw const StudioCloudException('请先登录农场管理员账号');
    }
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    if (session.authRealm == 'farm_staff') {
      throw const StudioCloudException('农场成员账号不能注册新的农场主体');
    }
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    if (session.user.emailVerified) {
      final workspaces = await api.listWorkspaces(session.accessToken);
      final owned =
          workspaces.where((item) => item['role'] == 'owner').firstOrNull;
      if (owned != null) {
        final remoteId = owned['id'] as String;
        await ref.read(studioDaoProvider).bindRemoteWorkspace(
              remoteId,
              accountScope: '${session.serverBaseUrl}|farm:$remoteId',
              name: owned['name'] as String?,
            );
        return;
      }
    }
    final local = await ref.read(studioDaoProvider).getDefaultSnapshot();
    final remoteId = const Uuid().v4();
    await api.createWorkspace(
      accessToken: session.accessToken,
      id: remoteId,
      name: local.workspace.name,
    );
    await ref
        .read(studioDaoProvider)
        .setRemoteWorkspaceId(local.workspace.id, remoteId);
    await ref.read(studioDaoProvider).bindRemoteWorkspace(
          remoteId,
          accountScope: '${session.serverBaseUrl}|farm:$remoteId',
          name: local.workspace.name,
        );
  }

  Future<StudioRemoteShareLink> createShareLink(
    StudioOrder order, {
    int expiresInDays = 30,
    required String portalPassword,
  }) async {
    await sync();
    final auth = ref.read(appAuthProvider);
    final endpoint = auth.endpoint!;
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final api = StudioApiClient(
      baseUri: endpoint,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final workspace =
        (await ref.read(studioDaoProvider).getDefaultSnapshot()).workspace;
    final link = await api.createShareLink(
      accessToken: session.accessToken,
      workspaceId: workspace.remoteId ?? order.workspaceId,
      orderId: order.id,
      expiresInDays: expiresInDays,
      portalPassword: portalPassword,
    );
    await ref.read(studioDaoProvider).saveShareLink(
          id: link.id,
          workspaceId: order.workspaceId,
          orderId: order.id,
          tokenPreview: link.tokenPreview,
          publicUrl: link.publicUrl.toString(),
          expiresAt: link.expiresAt,
          passwordRequired: true,
        );
    return link;
  }

  Future<void> revokeShareLink(StudioShareLink link) async {
    final auth = ref.read(appAuthProvider);
    final endpoint = auth.endpoint;
    if (endpoint == null || !auth.isSignedIn) {
      throw const StudioCloudException('请先登录 sohun 云服务');
    }
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final api = StudioApiClient(
      baseUri: endpoint,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final workspace =
        (await ref.read(studioDaoProvider).getDefaultSnapshot()).workspace;
    await api.revokeShareLink(
      accessToken: session.accessToken,
      workspaceId: workspace.remoteId ?? link.workspaceId,
      shareId: link.id,
    );
    await ref.read(studioDaoProvider).revokeShareLink(link.id);
  }

  Future<Map<String, dynamic>> getFarmOrganizationProfile() async {
    await sync();
    final auth = ref.read(appAuthProvider);
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final workspace =
        (await ref.read(studioDaoProvider).getDefaultSnapshot()).workspace;
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    return api.getFarmOrganization(
      accessToken: session.accessToken,
      organizationId: workspace.remoteId ?? workspace.id,
    );
  }

  Future<Map<String, dynamic>> saveFarmOrganizationProfile(
    Map<String, dynamic> profile, {
    bool submitForVerification = false,
  }) async {
    await sync();
    final auth = ref.read(appAuthProvider);
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final workspace =
        (await ref.read(studioDaoProvider).getDefaultSnapshot()).workspace;
    final organizationId = workspace.remoteId ?? workspace.id;
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final updated = await api.updateFarmOrganization(
      accessToken: session.accessToken,
      organizationId: organizationId,
      profile: profile,
    );
    if (submitForVerification) {
      await api.submitFarmVerification(
        accessToken: session.accessToken,
        organizationId: organizationId,
      );
    }
    await ref.read(studioDaoProvider).recordActivity(
          workspaceId: workspace.id,
          actionCode: submitForVerification
              ? 'organization.verification_submitted'
              : 'organization.profile_updated',
          entityType: 'organization',
          entityId: organizationId,
          summary: submitForVerification ? '提交农场主体资料审核' : '保存农场主体资料',
        );
    ref.invalidate(farmAuditLogsProvider);
    return updated;
  }

  Future<Map<String, dynamic>> createFarmStaff({
    required String displayName,
    required String loginName,
    List<String> roleCodes = const ['member'],
    String? primaryRoleCode,
    String? employeeNo,
    String? phone,
    String? recoveryEmail,
  }) async {
    await sync();
    final auth = ref.read(appAuthProvider);
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final dao = ref.read(studioDaoProvider);
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final organizationId = workspace.remoteId ?? workspace.id;
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final result = await api.createFarmStaff(
      accessToken: session.accessToken,
      organizationId: organizationId,
      displayName: displayName,
      loginName: loginName,
      roleCodes: const ['member'],
      primaryRoleCode: 'member',
      employeeNo: employeeNo,
      phone: phone,
      recoveryEmail: recoveryEmail,
    );
    final remote = await api.getSnapshot(
      accessToken: session.accessToken,
      workspaceId: organizationId,
    );
    await dao.mergeRemoteMembers(remote.members);
    final member = result['member'];
    final memberId = member is Map ? member['id']?.toString() : null;
    if (memberId != null) {
      await dao.recordActivity(
        workspaceId: workspace.id,
        actionCode: 'member.created',
        entityType: 'member',
        entityId: memberId,
        summary: '创建成员 ${displayName.trim()}（账号 ${loginName.trim()}）',
      );
    }
    ref.invalidate(studioSnapshotProvider);
    ref.invalidate(studioActivityEventsProvider);
    ref.invalidate(farmAuditLogsProvider);
    return result;
  }

  Future<Map<String, dynamic>> resetFarmStaffCredential(String memberId) async {
    final auth = ref.read(appAuthProvider);
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final dao = ref.read(studioDaoProvider);
    final snapshot = await dao.getDefaultSnapshot();
    final workspace = snapshot.workspace;
    final memberName = snapshot.members
        .where((item) => item.id == memberId)
        .firstOrNull
        ?.displayName;
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    final result = await api.resetFarmStaffCredential(
      accessToken: session.accessToken,
      organizationId: workspace.remoteId ?? workspace.id,
      memberId: memberId,
    );
    final remote = await api.getSnapshot(
      accessToken: session.accessToken,
      workspaceId: workspace.remoteId ?? workspace.id,
    );
    await dao.mergeRemoteMembers(remote.members);
    await dao.recordActivity(
      workspaceId: workspace.id,
      actionCode: 'member.credential_reset',
      entityType: 'member',
      entityId: memberId,
      summary: '重置成员 ${memberName ?? memberId} 的登录密码',
    );
    ref.invalidate(studioSnapshotProvider);
    ref.invalidate(studioActivityEventsProvider);
    ref.invalidate(farmAuditLogsProvider);
    return result;
  }

  Future<void> updateFarmStaff(
    String memberId, {
    String? displayName,
    List<String>? roleCodes,
    String? primaryRoleCode,
    String? accountStatus,
  }) async {
    final auth = ref.read(appAuthProvider);
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    final dao = ref.read(studioDaoProvider);
    final before = await dao.getDefaultSnapshot();
    final workspace = before.workspace;
    final target =
        before.members.where((item) => item.id == memberId).firstOrNull;
    final organizationId = workspace.remoteId ?? workspace.id;
    final api = StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    );
    await api.updateFarmStaff(
      accessToken: session.accessToken,
      organizationId: organizationId,
      memberId: memberId,
      displayName: displayName,
      roleCodes: roleCodes,
      primaryRoleCode: primaryRoleCode,
      accountStatus: accountStatus,
    );
    final remote = await api.getSnapshot(
      accessToken: session.accessToken,
      workspaceId: organizationId,
    );
    await dao.mergeRemoteMembers(remote.members);
    final actionCode = switch (accountStatus) {
      'removed' => 'member.removed',
      'deactivated' => 'member.deactivated',
      'active' => 'member.activated',
      _ => 'member.updated',
    };
    final actionSummary = switch (accountStatus) {
      'removed' => '删除成员 ${target?.displayName ?? memberId}（历史操作记录已保留）',
      'deactivated' => '停用成员 ${target?.displayName ?? memberId}',
      'active' => '启用成员 ${target?.displayName ?? memberId}',
      _ => '更新成员 ${target?.displayName ?? memberId} 的资料',
    };
    await dao.recordActivity(
      workspaceId: workspace.id,
      actionCode: actionCode,
      entityType: 'member',
      entityId: memberId,
      summary: actionSummary,
    );
    ref.invalidate(studioSnapshotProvider);
    ref.invalidate(studioActivityEventsProvider);
    ref.invalidate(farmAuditLogsProvider);
  }

  Future<void> removeFarmStaff(String memberId) {
    return updateFarmStaff(memberId, accountStatus: 'removed');
  }

  Future<List<StudioRemoteAuditLog>> getFarmAuditLogs() async {
    final auth = ref.read(appAuthProvider);
    final session = await ref
        .read(appAuthProvider.notifier)
        .ensureValidSession(minimumValidity: const Duration(minutes: 2));
    if (session.authRealm == 'farm_staff') {
      throw const StudioCloudException('只有农场管理员可以查看完整操作记录');
    }
    final workspace =
        (await ref.read(studioDaoProvider).getDefaultSnapshot()).workspace;
    return StudioApiClient(
      baseUri: auth.endpoint!,
      httpClient: ref.read(communityHttpClientProvider),
    ).getFarmAuditLogs(
      accessToken: session.accessToken,
      organizationId: workspace.remoteId ?? workspace.id,
    );
  }

  Future<Map<String, dynamic>> _serialize(StudioSnapshot studio) async {
    final tombstones = await ref.read(studioDaoProvider).getSyncTombstones();
    final consumables =
        await ref.read(consumableDaoProvider).getFarm(studio.workspace.id);
    final consumableMetadata =
        await ref.read(consumableDaoProvider).getFarmConsumableMetadata(
              consumables.map((item) => item.id),
              workspaceId: studio.workspace.id,
            );
    final printers =
        await ref.read(printerDaoProvider).getAllPrintersWithChannels();
    final serialByPrinterId = {
      for (final item in printers)
        if (item.serial != null) item.printer.id: item.serial!,
    };
    String? printerRefForSerial(String? serial) =>
        serial == null || serial.trim().isEmpty
            ? null
            : crypto.sha256.convert(utf8.encode(serial.trim())).toString();
    final printerById = {
      for (final item in printers) item.printer.id: item.printer,
    };
    final channelRefById = <int, String>{
      for (final item in printers)
        if (printerRefForSerial(item.serial) case final printerRef?)
          for (final channel in item.channels)
            channel.channel.id: '$printerRef:${channel.channel.channelIndex}',
    };
    final fleet = ref.read(printerFleetConnectionManagerProvider);
    final consumableById = {for (final item in consumables) item.id: item};
    String iso(DateTime value) => value.toUtc().toIso8601String();
    return {
      'schemaVersion': 2,
      'deletedEntities': tombstones,
      'workspace': {
        'id': studio.workspace.id,
        'name': studio.workspace.name,
        'updatedAt': iso(studio.workspace.updatedAt),
      },
      'customers': [
        for (final item in studio.customers)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'name': item.name,
            'contactName': item.contactName,
            'phone': item.phone,
            'email': item.email,
            'note': item.note,
            'archived': item.archived,
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
          },
      ],
      'orders': [
        for (final item in studio.orders)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'customerId': item.customerId,
            'orderNo': item.orderNo,
            'title': item.title,
            'status': item.status.name,
            'dueAt': item.dueAt == null ? null : iso(item.dueAt!),
            'totalPrice': item.totalPrice,
            'note': item.note,
            'publicNote': item.publicNote,
            'portalVideoEnabled': item.portalVideoEnabled,
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
          },
      ],
      'workOrders': [
        for (final item in studio.workOrders)
          () {
            final serial = item.printerId == null
                ? null
                : serialByPrinterId[item.printerId!];
            final fleetState = serial == null ? null : fleet[serial];
            final status = fleetState?.lastStatus;
            final activePrint = status?.gcodeState == BambuGcodeState.running ||
                status?.gcodeState == BambuGcodeState.pause ||
                status?.gcodeState == BambuGcodeState.prepare;
            final localPrinter =
                item.printerId == null ? null : printerById[item.printerId!];
            final printerName = localPrinter?.name?.trim().isNotEmpty == true
                ? localPrinter!.name!.trim()
                : fleetState?.reportedModel?.trim().isNotEmpty == true
                    ? fleetState!.reportedModel!.trim()
                    : localPrinter?.model;
            return {
              'id': item.id,
              'workspaceId': item.workspaceId,
              'orderId': item.orderId,
              'productionPlateId': item.productionPlateId,
              'title': item.title,
              'quantity': item.quantity,
              'completedQuantity': item.completedQuantity,
              'status': item.status.name,
              'assignedMemberId': item.assignedMemberId,
              'estimatedSeconds': item.estimatedSeconds,
              'materialCostSnapshot': item.materialCostSnapshot,
              'quotedPriceSnapshot': item.quotedPriceSnapshot,
              'note': item.note,
              'printerRef': printerRefForSerial(serial),
              'printerName': printerName,
              'progressPercent': status?.mcPercent ?? 0,
              'currentLayer': status?.currLayer ?? 0,
              'totalLayers': status?.totalLayers ?? 0,
              'remainingMinutes': status?.mcRemainingTime ?? 0,
              'activePrint': activePrint,
              'createdAt': iso(item.createdAt),
              'updatedAt': iso(item.updatedAt),
            };
          }(),
      ],
      'workOrderMaterials': [
        for (final item in studio.workOrderMaterials)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'workOrderId': item.workOrderId,
            'productionPlateId': item.productionPlateId,
            'toolIndex': item.toolIndex,
            'materialType': item.materialType,
            'colorHex': item.colorHex,
            'sku': item.sku,
            'estimatedGrams': item.estimatedGrams,
            'consumableUid': item.consumableId == null
                ? null
                : consumableById[item.consumableId!]?.uid,
            'printerChannelRef': item.printerChannelId == null
                ? null
                : channelRefById[item.printerChannelId!],
            'reservedGrams': item.reservedGrams,
            'consumedGrams': item.consumedGrams,
            'status': item.status.name,
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
            'settledAt': item.settledAt == null ? null : iso(item.settledAt!),
          },
      ],
      'printAttempts': [
        for (final item in studio.printAttempts)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'workOrderId': item.workOrderId,
            'attemptNo': item.attemptNo,
            'printerRef': printerRefForSerial(item.printerSerial),
            'outcome': item.outcome.code,
            'progressPercent': item.progressPercent,
            'consumedGrams': item.consumedGrams,
            'materialCost': item.materialCost,
            'failureReason': item.failureReason,
            'errorCode': item.errorCode,
            'startedAt': item.startedAt == null ? null : iso(item.startedAt!),
            'endedAt': iso(item.endedAt),
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
          },
      ],
      'productionPackages': [
        for (final item in studio.productionPackages)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'orderId': item.orderId,
            'sourceName': item.sourceName,
            'artifactSha256': item.artifactSha256,
            'artifactKind': item.artifactKind,
            'slicerName': item.slicerName,
            'slicerVersion': item.slicerVersion,
            'targetModel': item.targetModel,
            'nozzleDiameter': item.nozzleDiameter,
            'createdAt': iso(item.createdAt),
          },
      ],
      'productionPlates': [
        for (final item in studio.productionPlates)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'orderId': item.orderId,
            'packageId': item.packageId,
            'plateIndex': item.plateIndex,
            'name': item.name,
            'requiredRuns': item.requiredRuns,
            'estimatedSeconds': item.estimatedSeconds,
            'estimatedGrams': item.estimatedGrams,
            'sliceStatus': item.sliceStatus.name,
            'sliceArtifactSha256': item.sliceArtifactSha256,
            'autoEjectEnabled': item.autoEjectEnabled,
            'totalLayers': item.totalLayers,
            'toolChangeCount': item.toolChangeCount,
            'filaments': [
              for (final filament in item.filaments)
                {
                  'toolIndex': filament.toolIndex,
                  'grams': filament.grams,
                  'vendor': filament.vendor,
                  'materialType': filament.materialType,
                  'colorHex': filament.colorHex,
                  'trayId': filament.trayId,
                  'sku': filament.sku,
                  'usedForObject': filament.usedForObject,
                  'usedForSupport': filament.usedForSupport,
                  'groupId': filament.groupId,
                  'nozzleDiameter': filament.nozzleDiameter,
                  'volumeType': filament.volumeType,
                },
            ],
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
          },
      ],
      'orderItems': [
        for (final item in studio.orderItems)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'orderId': item.orderId,
            'packageId': item.packageId,
            'plateId': item.plateId,
            'sourceKey': item.sourceKey,
            'name': item.name,
            'perRunQuantity': item.perRunQuantity,
            'requiredQuantity': item.requiredQuantity,
            'createdAt': iso(item.createdAt),
          },
      ],
      'quotes': [
        for (final item in studio.quotes)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'customerId': item.customerId,
            'quoteNo': item.quoteNo,
            'title': item.title,
            'status': item.status.name,
            'materialLabel': item.materialLabel,
            'estimatedGrams': item.estimatedGrams,
            'materialCostPerKgSnapshot': item.materialCostPerKgSnapshot,
            'machineHours': item.machineHours,
            'machineRatePerHour': item.machineRatePerHour,
            'laborHours': item.laborHours,
            'laborRatePerHour': item.laborRatePerHour,
            'electricityCost': item.electricityCost,
            'packagingCost': item.packagingCost,
            'riskPercent': item.riskPercent,
            'markupPercent': item.markupPercent,
            'totalCost': item.totalCost,
            'quotedPrice': item.quotedPrice,
            'note': item.note,
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
          },
      ],
      'inventoryItems': [
        for (final item in consumables)
          () {
            final metadata = consumableMetadata[item.id];
            return {
              'uid': item.uid,
              'manufacturer': item.manufacturer,
              'model': item.model,
              'materialType': item.materialType,
              'colorHex': item.colorHex,
              'colorName': item.colorName,
              'totalGrams': item.totalGrams,
              'remainingGrams': item.remainingGrams,
              'batchNo': item.batchNo,
              'purchaseDate':
                  item.purchaseDate == null ? null : iso(item.purchaseDate!),
              'archived': metadata?.archived ?? false,
              'archivedAt': metadata?.archivedAt == null
                  ? null
                  : iso(metadata!.archivedAt!),
              'brandCode': metadata?.brandCode,
              'colorMode': metadata?.colorMode ?? 'solid',
              'secondaryColorHex': metadata?.secondaryColorHex,
              'createdAt': iso(item.createdAt),
              'updatedAt': iso(item.updatedAt),
            };
          }(),
      ],
      'inventoryEvents': [
        for (final item in studio.inventoryEvents)
          if (consumableById[item.consumableId] case final consumable?)
            {
              'id': item.id,
              'workspaceId': item.workspaceId,
              'consumableUid': consumable.uid,
              'type': item.type.name,
              'deltaGrams': item.deltaGrams,
              'reason': item.reason,
              'memberId': item.memberId,
              'createdAt': iso(item.createdAt),
            },
      ],
      'inventoryBatches': [
        for (final item in studio.inventoryBatches)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'batchNo': item.batchNo,
            'supplier': item.supplier,
            'receivedAt': iso(item.receivedAt),
            'rollCount': item.rollCount,
            'totalGrams': item.totalGrams,
            'note': item.note,
            'memberId': item.memberId,
            'createdAt': iso(item.createdAt),
            'updatedAt': iso(item.updatedAt),
          },
      ],
      'inventoryBatchItems': [
        for (final item in studio.inventoryBatchItems)
          if (consumableById[item.consumableId] case final consumable?)
            {
              'id': item.id,
              'batchId': item.batchId,
              'consumableUid': consumable.uid,
              'rollCount': item.rollCount,
              'gramsPerRoll': item.gramsPerRoll,
              'unitCost': item.unitCost,
              'voided': item.voided,
              'voidReason': item.voidReason,
              'voidedAt': item.voidedAt == null ? null : iso(item.voidedAt!),
              'createdAt': iso(item.createdAt),
              'updatedAt': iso(item.updatedAt),
            },
      ],
      'activityEvents': [
        for (final item in studio.activityEvents)
          {
            'id': item.id,
            'workspaceId': item.workspaceId,
            'actorMemberId': item.actorMemberId,
            'actorDisplayName': item.actorDisplayName,
            'actorIdentity': item.actorIdentity,
            'actionCode': item.actionCode,
            'entityType': item.entityType,
            'entityId': item.entityId,
            'summary': item.summary,
            'createdAt': iso(item.createdAt),
          },
      ],
    };
  }
}

final studioCloudServiceProvider = Provider<StudioCloudService>(
  StudioCloudService.new,
);

class StudioSyncController extends StateNotifier<StudioSyncState> {
  StudioSyncController(this.ref, {required this.active})
      : super(
          active
              ? const StudioSyncState(phase: StudioSyncPhase.localOnly)
              : const StudioSyncState.disabled(),
        ) {
    if (!active) return;
    _subscription = ref.read(studioDaoProvider).onChange.listen((_) {
      _schedule();
    });
    ref.listen<Map<String, FleetPrinterState>>(
      printerFleetConnectionManagerProvider,
      (previous, next) {
        final progressChanged = next.entries.any((entry) {
          final before = previous?[entry.key]?.lastStatus;
          final after = entry.value.lastStatus;
          return before?.gcodeState != after?.gcodeState ||
              before?.mcPercent != after?.mcPercent ||
              before?.currLayer != after?.currLayer ||
              before?.mcRemainingTime != after?.mcRemainingTime;
        });
        if (!progressChanged || _fleetThrottle != null) return;
        _fleetThrottle = Timer(const Duration(seconds: 15), () {
          _fleetThrottle = null;
          _schedule(delay: Duration.zero);
        });
      },
    );
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) => _schedule());
    _schedule(delay: Duration.zero);
  }

  final Ref ref;
  final bool active;
  StreamSubscription<void>? _subscription;
  Timer? _debounce;
  Timer? _periodic;
  Timer? _fleetThrottle;
  bool _running = false;
  bool _requested = false;
  bool _showNextRun = false;

  void requestNow({bool visible = true}) =>
      _schedule(delay: Duration.zero, visible: visible);

  void _schedule({
    Duration delay = const Duration(milliseconds: 1200),
    bool visible = false,
  }) {
    if (!active) return;
    _showNextRun = _showNextRun || visible;
    _debounce?.cancel();
    _debounce = Timer(delay, _run);
  }

  Future<void> _run() async {
    if (_running) {
      _requested = true;
      return;
    }
    _running = true;
    final showActivity = _showNextRun;
    _showNextRun = false;
    if (showActivity) {
      state = StudioSyncState(
        phase: StudioSyncPhase.syncing,
        lastSyncedAt: state.lastSyncedAt,
      );
    }
    try {
      await ref.read(studioCloudServiceProvider).sync();
      state = StudioSyncState(
        phase: StudioSyncPhase.synced,
        lastSyncedAt: DateTime.now(),
      );
    } catch (error) {
      state = StudioSyncState(
        phase: StudioSyncPhase.error,
        lastSyncedAt: state.lastSyncedAt,
        message: error.toString(),
      );
    } finally {
      _running = false;
      if (_requested) {
        _requested = false;
        _schedule();
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _debounce?.cancel();
    _periodic?.cancel();
    _fleetThrottle?.cancel();
    super.dispose();
  }
}

final studioSyncControllerProvider =
    StateNotifierProvider<StudioSyncController, StudioSyncState>((ref) {
  final enabled = ref.watch(studioModeEnabledProvider);
  final signedIn =
      ref.watch(appAuthProvider.select((state) => state.isSignedIn));
  return StudioSyncController(ref, active: enabled && signedIn);
});
