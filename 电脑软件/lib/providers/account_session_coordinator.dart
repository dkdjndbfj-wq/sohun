import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/printer/bambu_cloud_models.dart';

/// 账号会话协调器：打破 `bambuAccountManagerProvider` ↔ `bambuCloudProvider` 的循环依赖。
///
/// 原本的循环：
/// - `BambuAccountManagerNotifier.switchAccount` 调用
///   `ref.read(bambuCloudProvider.notifier).setActiveSession(session)`
/// - `BambuCloudNotifier._completeLogin` / `logout` 又反向调用
///   `ref.read(bambuAccountManagerProvider.notifier).addAccount/refresh/removeAccount`
///
/// 拆解方案：
/// - `BambuAccountManagerNotifier` 切换账号时只更新本协调器（写 session 状态），
///   不再直接调用 `bambuCloudProvider.notifier.setActiveSession`。
/// - `BambuCloudNotifier` 在构造时通过 `ref.listen` 监听本协调器，
///   协调器状态变化时自动应用新 session（调用内部 `setActiveSession`）。
///
/// 这样 `bambuAccountManagerProvider → bambuCloudProvider` 的直接调用被切断，
/// 环被打破为：
///   bambuAccountManagerProvider → accountSessionCoordinatorProvider
///   accountSessionCoordinatorProvider ← bambuCloudProvider (ref.listen)
///   bambuCloudProvider → bambuAccountManagerProvider (addAccount/refresh/remove，
///                        单向调用，不构成环)
///
/// 注意：本协调器只承载「当前活跃 session」这一份状态，不持久化（持久化仍由
/// `BambuCloudSessionStore` 负责）。初始值为 null，`BambuCloudNotifier` 启动时
/// 仍走 `_restoreSession` 从磁盘恢复，与本协调器并行不冲突。
final accountSessionCoordinatorProvider =
    StateProvider<BambuCloudSession?>((ref) {
  return null;
});
