import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/external/community/community_api_client.dart';
import '../data/models/app_auth.dart';
import '../data/models/community_preset.dart';
import '../data/models/print_parameter.dart';
import 'app_auth_provider.dart';

class CommunityPresetQuery {
  final String query;
  final String? material;
  final String? scene;
  final String? printer;
  final String sort;

  const CommunityPresetQuery({
    this.query = '',
    this.material,
    this.scene,
    this.printer,
    this.sort = 'recommended',
  });
}

class CommunityPresetFeedState {
  final List<CommunityPreset> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasLoaded;
  final String? nextCursor;
  final String? errorMessage;
  final DateTime? updatedAt;
  final CommunityPresetQuery lastQuery;

  const CommunityPresetFeedState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasLoaded = false,
    this.nextCursor,
    this.errorMessage,
    this.updatedAt,
    this.lastQuery = const CommunityPresetQuery(),
  });

  CommunityPresetFeedState copyWith({
    List<CommunityPreset>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasLoaded,
    Object? nextCursor = _unset,
    Object? errorMessage = _unset,
    Object? updatedAt = _unset,
    CommunityPresetQuery? lastQuery,
  }) {
    return CommunityPresetFeedState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      nextCursor:
          nextCursor == _unset ? this.nextCursor : nextCursor as String?,
      errorMessage:
          errorMessage == _unset ? this.errorMessage : errorMessage as String?,
      updatedAt: updatedAt == _unset ? this.updatedAt : updatedAt as DateTime?,
      lastQuery: lastQuery ?? this.lastQuery,
    );
  }
}

const _unset = Object();

class CommunityPresetFeedNotifier
    extends StateNotifier<CommunityPresetFeedState> {
  final Ref _ref;
  final bool mine;
  Future<void>? _refreshOperation;
  Future<void>? _loadMoreOperation;
  int _requestGeneration = 0;

  CommunityPresetFeedNotifier(this._ref, {this.mine = false})
      : super(const CommunityPresetFeedState());

  Future<void> refresh({
    CommunityPresetQuery? query,
    bool force = false,
  }) {
    final effectiveQuery = query ?? state.lastQuery;
    final current = _refreshOperation;
    if (current != null && !force) return current;
    final operation = _performRefresh(effectiveQuery);
    _refreshOperation = operation;
    operation.whenComplete(() {
      if (identical(_refreshOperation, operation)) _refreshOperation = null;
    });
    return operation;
  }

  Future<void> _performRefresh(CommunityPresetQuery query) async {
    final generation = ++_requestGeneration;
    final api = _ref.read(communityPresetApiProvider);
    if (api == null) {
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        hasLoaded: true,
        errorMessage: 'sohun 云暂时不可用，请稍后重试',
        lastQuery: query,
      );
      return;
    }
    state = state.copyWith(
      isLoading: true,
      errorMessage: null,
      lastQuery: query,
    );
    try {
      var session = _ref.read(appAuthProvider).session;
      if (session != null) {
        try {
          session =
              await _ref.read(appAuthProvider.notifier).ensureValidSession();
        } on CommunityApiException catch (error) {
          if (mine || !error.isAuthenticationFailure) rethrow;
          session = null;
        }
      }
      final page = await api.listPresets(
        query: query.query,
        material: query.material,
        scene: query.scene,
        printer: query.printer,
        sort: query.sort,
        accessToken: session?.accessToken,
        mine: mine,
      );
      if (!mounted || generation != _requestGeneration) return;
      state = CommunityPresetFeedState(
        items: page.items,
        hasLoaded: true,
        nextCursor: page.nextCursor,
        updatedAt: DateTime.now(),
        lastQuery: query,
      );
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      state = state.copyWith(
        isLoading: false,
        hasLoaded: true,
        errorMessage: _messageFor(error),
        lastQuery: query,
      );
    }
  }

  Future<void> loadMore() {
    final current = _loadMoreOperation;
    if (current != null) return current;
    if (state.isLoading || state.nextCursor == null) {
      return Future<void>.value();
    }
    final operation = _performLoadMore();
    _loadMoreOperation = operation;
    operation.whenComplete(() {
      if (identical(_loadMoreOperation, operation)) _loadMoreOperation = null;
    });
    return operation;
  }

  Future<void> _performLoadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null) return;
    final generation = _requestGeneration;
    final api = _ref.read(communityPresetApiProvider);
    if (api == null) return;
    state = state.copyWith(isLoadingMore: true, errorMessage: null);
    try {
      var session = _ref.read(appAuthProvider).session;
      if (session != null) {
        try {
          session =
              await _ref.read(appAuthProvider.notifier).ensureValidSession();
        } on CommunityApiException catch (error) {
          if (mine || !error.isAuthenticationFailure) rethrow;
          session = null;
        }
      }
      final page = await api.listPresets(
        query: state.lastQuery.query,
        material: state.lastQuery.material,
        scene: state.lastQuery.scene,
        printer: state.lastQuery.printer,
        sort: state.lastQuery.sort,
        cursor: cursor,
        limit: 30,
        accessToken: session?.accessToken,
        mine: mine,
      );
      if (!mounted || generation != _requestGeneration) return;
      final seen = state.items.map((item) => item.publicationId).toSet();
      final appended = <CommunityPreset>[
        ...state.items,
        ...page.items.where((item) => seen.add(item.publicationId)),
      ];
      state = state.copyWith(
        items: appended,
        isLoadingMore: false,
        nextCursor: page.nextCursor,
        updatedAt: DateTime.now(),
      );
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      state = state.copyWith(
        isLoadingMore: false,
        errorMessage: _messageFor(error),
      );
    }
  }

  Future<CommunityPreset> publish(PrintParameterPreset preset) async {
    final api = _requireApi();
    final session = await _requireSession();
    final published = await api.publishPreset(
      accessToken: session.accessToken,
      preset: preset,
    );
    state = state.copyWith(
      items: [
        published,
        ...state.items.where(
          (item) => item.publicationId != published.publicationId,
        ),
      ],
      updatedAt: DateTime.now(),
      errorMessage: null,
    );
    return published;
  }

  Future<CommunityPreset> updatePublication({
    required CommunityPreset publication,
    required PrintParameterPreset preset,
  }) async {
    final api = _requireApi();
    final session = await _requireSession();
    final updated = await api.updatePublishedPreset(
      accessToken: session.accessToken,
      publicationId: publication.publicationId,
      revision: publication.revision,
      preset: preset,
      visibility: publication.visibility,
    );
    _replaceItem(updated);
    return updated;
  }

  Future<void> deletePublication(CommunityPreset publication) async {
    final api = _requireApi();
    final session = await _requireSession();
    await api.deletePublishedPreset(
      accessToken: session.accessToken,
      publicationId: publication.publicationId,
    );
    state = state.copyWith(
      items: state.items
          .where((item) => item.publicationId != publication.publicationId)
          .toList(growable: false),
      updatedAt: DateTime.now(),
    );
  }

  Future<void> toggleLike(CommunityPreset publication) async {
    final api = _requireApi();
    final session = await _requireSession();
    final updated = await api.setPresetLiked(
      accessToken: session.accessToken,
      publicationId: publication.publicationId,
      liked: !publication.likedByMe,
    );
    _replaceItem(updated);
  }

  Future<void> registerDownload(CommunityPreset publication) async {
    final api = _requireApi();
    await api.registerPresetDownload(publication.publicationId);
  }

  CommunityPresetApi _requireApi() {
    final api = _ref.read(communityPresetApiProvider);
    if (api == null) {
      throw const CommunityApiException(
        'sohun 云暂时不可用，请稍后重试',
        category: CommunityApiErrorCategory.configuration,
      );
    }
    return api;
  }

  Future<AppAuthSession> _requireSession() async {
    if (_ref.read(appAuthProvider).session == null) {
      throw const CommunityApiException(
        '请先登录工作台账号',
        category: CommunityApiErrorCategory.authentication,
      );
    }
    return _ref.read(appAuthProvider.notifier).ensureValidSession();
  }

  void _replaceItem(CommunityPreset updated) {
    state = state.copyWith(
      items: state.items
          .map(
            (item) =>
                item.publicationId == updated.publicationId ? updated : item,
          )
          .toList(growable: false),
      updatedAt: DateTime.now(),
      errorMessage: null,
    );
  }

  static String _messageFor(Object error) {
    if (error is CommunityApiException) return error.message;
    if (error is FormatException) return error.message;
    return '参数广场读取失败，请稍后重试';
  }
}

final communityPresetFeedProvider = StateNotifierProvider<
    CommunityPresetFeedNotifier, CommunityPresetFeedState>((ref) {
  final notifier = CommunityPresetFeedNotifier(ref);
  ref.listen(
    appAuthProvider.select((state) => (state.endpoint, state.user?.id)),
    (previous, next) {
      if (previous != next) notifier.refresh(force: true);
    },
  );
  return notifier;
});

final myCommunityPresetFeedProvider = StateNotifierProvider<
    CommunityPresetFeedNotifier, CommunityPresetFeedState>((ref) {
  final notifier = CommunityPresetFeedNotifier(ref, mine: true);
  ref.listen(
    appAuthProvider.select((state) => (state.endpoint, state.user?.id)),
    (previous, next) {
      if (previous != next) notifier.refresh(force: true);
    },
  );
  return notifier;
});

/// Incremented whenever the workspace navigates back to the parameter plaza.
final parameterPlazaActivationProvider = StateProvider<int>((ref) => 0);

// ===== Phase E-4：社区可信汇总与举报 =====

const _trustCachePrefix = 'community_trust_summary_v1_';

Future<CommunityTrustSummary?> _readTrustCache(String publicationId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_trustCachePrefix$publicationId');
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return CommunityTrustSummary.fromJson(
      Map<String, dynamic>.from(decoded),
    ).copyWith(isStale: true);
  } catch (_) {
    return null;
  }
}

Future<void> _writeTrustCache(
  String publicationId,
  CommunityTrustSummary summary,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_trustCachePrefix$publicationId',
      jsonEncode(summary.toCacheJson()),
    );
  } catch (_) {
    // Cache persistence must never make the public feed fail.
  }
}

/// 拉取指定公开参数集的可信度汇总。
///
/// - 服务器未配置 / 未登录时返回 null，UI 显示"暂无可信数据"。
/// - 失败时不抛异常，返回 null 以保证 UI 不崩。
/// - 自动缓存最近一次结果，避免重复请求。
final trustSummaryProvider =
    FutureProvider.autoDispose.family<CommunityTrustSummary?, String>(
  (ref, publicationId) async {
    final api = ref.watch(communityTrustApiProvider);
    final cached = await _readTrustCache(publicationId);
    if (api == null) return cached;
    // 拉取汇总不需要强制登录，但带 token 时服务端可返回更详细字段
    final notifier = ref.read(appAuthProvider.notifier);
    await notifier.ready;
    final session = ref.read(appAuthProvider).session;
    String? accessToken;
    if (session != null) {
      try {
        final valid = await notifier.ensureValidSession();
        accessToken = valid.accessToken;
      } catch (_) {
        accessToken = null;
      }
    }
    try {
      final fetched = await api.fetchTrustSummary(
        publicationId: publicationId,
        accessToken: accessToken,
      );
      final current = fetched.copyWith(
        cachedAt: DateTime.now(),
        isStale: false,
      );
      await _writeTrustCache(publicationId, current);
      return current;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[TrustSummary] 拉取失败(publicationId=$publicationId): $error');
      }
      return cached;
    }
  },
);

final authorReputationProvider = FutureProvider.autoDispose
    .family<CommunityAuthorReputation?, String>((ref, handle) async {
  final api = ref.watch(communityTrustApiProvider);
  if (api == null || handle.trim().isEmpty) return null;
  try {
    return await api.fetchAuthorReputation(handle: handle);
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[AuthorReputation] 拉取失败(handle=$handle): $error');
    }
    return null;
  }
});

/// 举报结果状态。
class CommunityReportResult {
  final bool success;
  final String? errorMessage;

  const CommunityReportResult({required this.success, this.errorMessage});
}

/// 提交参数举报。
///
/// 返回成功回执；失败时返回 [CommunityReportResult.error] 含错误消息。
/// 调用方应在 UI 中禁用提交按钮防止重复点击。
Future<CommunityReportResult> submitPresetReport(
  WidgetRef ref, {
  required String publicationId,
  required String reason,
  String? note,
}) async {
  final api = ref.read(communityTrustApiProvider);
  if (api == null) {
    return const CommunityReportResult(
      success: false,
      errorMessage: 'sohun 云暂时不可用，请稍后重试',
    );
  }
  final notifier = ref.read(appAuthProvider.notifier);
  await notifier.ready;
  final session = ref.read(appAuthProvider).session;
  if (session == null) {
    return const CommunityReportResult(
      success: false,
      errorMessage: '请先登录工作台账号',
    );
  }
  try {
    final valid = await notifier.ensureValidSession();
    await api.reportPreset(
      accessToken: valid.accessToken,
      publicationId: publicationId,
      reason: reason,
      note: note,
    );
    return const CommunityReportResult(success: true);
  } on CommunityApiException catch (error) {
    return CommunityReportResult(
      success: false,
      errorMessage: error.message,
    );
  } catch (error) {
    return CommunityReportResult(
      success: false,
      errorMessage: '举报提交失败：$error',
    );
  }
}
