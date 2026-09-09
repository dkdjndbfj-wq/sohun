import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/printer/bambu_cloud_client.dart';
import '../data/external/printer/bambu_cloud_models.dart';
import 'bambu_cloud_provider.dart';

/// 拓竹云任务历史 Provider。
///
/// 调用 [BambuCloudClient.getTaskList] 拉取当前活跃账号的所有云端任务历史。
/// 拓竹 API 返回的任务记录含：实际耗材克数/长度、打印耗时、AMS 颜色映射、
/// 设备信息、起止时间等，是比本地缓存更权威的打印历史来源。
///
/// **使用场景**：
/// - 在打印历史页面叠加显示云端数据，做交叉对比
/// - 离线场景下查阅最近打印记录
/// - 多账号切换后查看不同账号下的任务历史
///
/// **刷新策略**：
/// - autoDispose：UI 退出后自动释放缓存
/// - 调用方通过 `ref.invalidate(bambuCloudTasksProvider)` 主动刷新
/// - 失败时不缓存错误，下次访问重新拉取
///
/// **未登录处理**：
/// - 当前 session 为 null 时返回空列表（不抛错），UI 应显示"请先登录拓竹账号"
final bambuCloudTasksProvider =
    FutureProvider.autoDispose<List<BambuCloudTask>>((ref) async {
  // 监听活跃 session 变化：账号切换后自动重拉
  final cloudState = ref.watch(bambuCloudProvider);
  final session = cloudState.session;
  if (session == null) {
    return const [];
  }
  try {
    return await BambuCloudClient.getTaskList(session);
  } catch (e) {
    debugPrint('[BambuCloudTasks] 拉取云端任务失败: $e');
    // 不缓存错误，让 UI 显示失败提示，下次访问重试
    rethrow;
  }
});
