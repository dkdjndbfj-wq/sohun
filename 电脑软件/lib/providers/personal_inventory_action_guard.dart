import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import 'consumable_provider.dart';
import 'database_provider.dart';

/// Keeps a dialog attached to the account that opened it. Ownership checks and
/// the resulting mutation share one transaction, including anonymous claims.
class PersonalInventoryActionGuard {
  PersonalInventoryActionGuard({
    required this.dao,
    required PersonalInventoryAccountScope Function() readScope,
  }) : _readScope = readScope,
       scope = readScope();

  factory PersonalInventoryActionGuard.fromRef(WidgetRef ref) =>
      PersonalInventoryActionGuard(
        dao: ref.read(consumableDaoProvider),
        readScope: () => ref.read(personalInventoryAccountScopeProvider),
      );

  factory PersonalInventoryActionGuard.fromContext(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    return PersonalInventoryActionGuard(
      dao: container.read(consumableDaoProvider),
      readScope: () => container.read(personalInventoryAccountScopeProvider),
    );
  }

  final ConsumableDao dao;
  final PersonalInventoryAccountScope scope;
  final PersonalInventoryAccountScope Function() _readScope;

  bool get isCurrent {
    final current = _readScope();
    return current.enforce == scope.enforce &&
        current.ownerAccount == scope.ownerAccount;
  }

  void assertCurrent() {
    if (!isCurrent) throw StateError('账号已切换，请关闭对话框后重试');
  }

  Future<T> run<T>(
    int consumableId,
    Future<T> Function() action, {
    bool claimAnonymous = true,
  }) => dao.transaction(() async {
    assertCurrent();
    if (scope.enforce &&
        !await dao.ensurePersonalConsumableAccess(
          consumableId,
          ownerAccount: scope.ownerAccount,
          claimAnonymous: claimAnonymous,
        )) {
      throw StateError('该耗材属于其他账号，请切回原账号后操作');
    }
    assertCurrent();
    final result = await action();
    assertCurrent();
    return result;
  });

  Future<void> checkAccess(int consumableId) =>
      run(consumableId, () async {}, claimAnonymous: false);
}
