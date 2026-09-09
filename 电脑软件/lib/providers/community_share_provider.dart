import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/community_share_service.dart';
import '../core/services/kill_switch_service.dart';
import '../data/database/daos/preset_result_dao.dart';
import '../data/external/community/community_api_client.dart';
import 'app_auth_provider.dart';
import 'database_provider.dart';

/// PresetResultDao 单例（参数效果闭环，raw SQL DAO）。
///
/// 不走 drift 代码生成，手动实例化。dispose 时释放内部 StreamController。
/// 与 [parameterPerformanceServiceProvider] 中的 DAO 实例独立，各自持有
/// 自己的 StreamController，互不影响。
final presetResultDaoProvider = Provider<PresetResultDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = PresetResultDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// 社区打印结果分享服务 Provider。
///
/// 当社区服务器未配置时 [communityTrustApiProvider] 返回 null，
/// 服务所有方法自动降级为 no-op。当 endpoint 变化时 Provider 重建，
/// 旧服务的定时器通过 [CommunityShareService.dispose] 取消。
final communityShareServiceProvider = Provider<CommunityShareService>((ref) {
  final apiClient = ref.watch(communityTrustApiProvider);
  final dao = ref.watch(presetResultDaoProvider);
  final service = CommunityShareService(
    apiClient: apiClient,
    resultDao: dao,
    accessTokenProvider: () async {
      final notifier = ref.read(appAuthProvider.notifier);
      await notifier.ready;
      final session = ref.read(appAuthProvider).session;
      if (session == null) return null;
      try {
        final valid = await notifier.ensureValidSession();
        return valid.accessToken;
      } catch (_) {
        return null;
      }
    },
    isShareEnabled: () =>
        ref.read(communityShareEnabledProvider) &&
        ref.read(killSwitchServiceProvider).isEnabled('community_share'),
  );
  ref.onDispose(service.dispose);
  return service;
});
