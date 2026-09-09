import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/personal_inventory_sync_service.dart';
import '../data/database/database.dart';
import 'app_auth_provider.dart';
import 'database_provider.dart';

/// 当前 sohun 账号的消耗记录（实时流，按时间倒序）。
final usageLogsProvider = StreamProvider<List<UsageLog>>((ref) {
  final session = ref.watch(appAuthProvider.select((state) => state.session));
  if (session != null && session.authRealm != 'personal') {
    return Stream.value(const <UsageLog>[]);
  }
  final owner = session == null
      ? ''
      : PersonalInventorySyncService.ownerAccountFor(session);
  return ref.watch(usageLogDaoProvider).watchPersonalForOwnerAccount(owner);
});
