import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import '../data/seed/printer_seed.dart';
import '../core/services/personal_inventory_sync_service.dart';
import 'app_auth_provider.dart';
import 'database_provider.dart';

/// The personal-inventory identity that applies to the current desktop
/// session. Farm sessions keep their existing workspace-owned inventory
/// rules, while signed-out and personal sessions must enforce local ownership.
class PersonalInventoryAccountScope {
  const PersonalInventoryAccountScope({
    required this.enforce,
    required this.ownerAccount,
  });

  final bool enforce;
  final String ownerAccount;

  bool allowsStoredOwner(String? storedOwner) {
    if (!enforce) return true;
    final stored = storedOwner?.trim().toLowerCase() ?? '';
    if (stored.isEmpty) return true;
    final current = ownerAccount.trim().toLowerCase();
    return current.isNotEmpty && stored == current;
  }
}

final personalInventoryAccountScopeProvider =
    Provider<PersonalInventoryAccountScope>((ref) {
      final session = ref.watch(
        appAuthProvider.select((state) => state.session),
      );
      if (session != null && session.authRealm != 'personal') {
        return const PersonalInventoryAccountScope(
          enforce: false,
          ownerAccount: '',
        );
      }
      return PersonalInventoryAccountScope(
        enforce: true,
        ownerAccount: session == null
            ? ''
            : PersonalInventorySyncService.ownerAccountFor(session),
      );
    });

/// 耗材库存列表（实时流）。新增/消耗/删除会自动刷新。
///
/// 个人库存按当前 sohun 服务器和稳定用户 ID 隔离。未登录时只显示尚未
/// 归属账号的本机库存；农场会话不进入个人库存流。
final consumablesProvider = StreamProvider<List<Consumable>>((ref) {
  final session = ref.watch(appAuthProvider.select((state) => state.session));
  if (session != null && session.authRealm != 'personal') {
    return Stream.value(const <Consumable>[]);
  }
  final owner = ref.watch(personalInventoryAccountScopeProvider).ownerAccount;
  return ref.watch(consumableDaoProvider).watchPersonalForOwnerAccount(owner);
});

/// Shared identity lookup for inventory totals, cards, and lifecycle badges.
/// Each registered 1 kg spool counts once; a low-weight remnant remains visible
/// for reconciliation even when it cannot be loaded again.
final personalRfidSpoolBindingsProvider =
    FutureProvider<Map<int, RfidSpoolBinding>>((ref) {
      final items =
          ref.watch(consumablesProvider).valueOrNull ?? const <Consumable>[];
      return ref
          .watch(consumableDaoProvider)
          .getRfidSpoolBindingsMap(items.map((c) => c.id));
    });

final personalRfidStockSourcesProvider =
    FutureProvider<Map<int, PersonalRfidStockSource>>((ref) {
      final items =
          ref.watch(consumablesProvider).valueOrNull ?? const <Consumable>[];
      return ref
          .watch(consumableDaoProvider)
          .getPersonalRfidStockSourcesMap(items.map((c) => c.id));
    });

final personalIndividualSpoolIdsProvider = Provider<Set<int>>(
  (ref) => {
    ...?ref.watch(personalRfidSpoolBindingsProvider).valueOrNull?.keys,
    ...?ref.watch(personalRfidStockSourcesProvider).valueOrNull?.keys,
  },
);

/// Account-scoped personal inventory for the Android extension. The provider
/// keeps the desktop stream as the source of truth while preventing another
/// sohun account's rows from appearing on a shared device.
final personalConsumablesByOwnerProvider =
    StreamProvider.family<List<Consumable>, String>((ref, ownerAccount) {
      return ref
          .watch(consumableDaoProvider)
          .watchPersonalForOwnerAccount(ownerAccount);
    });

/// 厂商库（实时流）。合并「预设热门厂商」+「已入库耗材中出现的厂商」。
/// 用户新建耗材时输入的新厂商会随耗材记录入库自动加入此处，下次即可在自动补全中出现。
final manufacturersProvider = StreamProvider<List<String>>((ref) {
  final dao = ref.watch(consumableDaoProvider);
  final session = ref.watch(appAuthProvider.select((state) => state.session));
  final Stream<List<Consumable>> inventory;
  if (session != null && session.authRealm != 'personal') {
    inventory = Stream.value(const <Consumable>[]);
  } else {
    final owner = session == null
        ? ''
        : PersonalInventorySyncService.ownerAccountFor(session);
    inventory = dao.watchPersonalForOwnerAccount(owner);
  }
  return inventory.map((items) {
    final set = <String>{};
    set.addAll(PrinterPresets.commonManufacturers);
    for (final c in items) {
      final m = c.manufacturer.trim();
      if (m.isNotEmpty) set.add(m);
    }
    return set.toList()..sort();
  });
});
