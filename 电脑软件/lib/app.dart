import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/personal_desktop_theme.dart';
import 'core/app_variant.dart';
import 'core/app_identity.dart';
import 'core/services/drying_reminder_service.dart';
import 'core/services/app_tray_menu.dart';
import 'core/services/notification_service.dart';
import 'core/services/printer_fault_monitor.dart';
import 'core/services/printer_fault_sync_service.dart';
import 'core/services/device_workbench_publisher.dart';
import 'features/diagnostics/printer_fault_center.dart';
import 'core/services/camera_diagnostics_telemetry.dart';
import 'core/services/product_issue_collector.dart';
import 'core/services/personal_inventory_sync_service.dart';
import 'core/services/theme_icon_service.dart';
import 'core/services/printer_fleet_connection_manager.dart';
import 'core/services/spool_change_detector.dart';
import 'core/releases/app_release_notes.dart';
import 'core/startup/startup_handoff.dart';
import 'core/theme/interaction_effects.dart';
import 'data/prefs/app_prefs.dart';
import 'data/external/printer/bambu_printer_models.dart';
import 'data/external/community/community_api_client.dart';
import 'data/prefs/onboarding_prefs.dart';
import 'data/prefs/release_notes_prefs.dart';
import 'features/onboarding/onboarding_wizard.dart';
import 'features/settings/settings_sheet.dart';
import 'features/print_task/spool_change_confirmation_dialog.dart';
import 'features/printers/personal_spool_removal_dialog.dart';
import 'features/print_task/external_multicolor_plan_dialog.dart';
import 'features/updates/whats_new_dialog.dart';
import 'features/updates/app_update_gate.dart';
import 'features/studio/farm_slice_intake_dialog.dart';
import 'features/studio/farm_print_removal_confirmation_dialog.dart';
import 'features/studio/farm_spool_change_confirmation_dialog.dart';
import 'features/studio/farm_work_order_dialog.dart';
import 'providers/onboarding_provider.dart';
import 'providers/database_provider.dart';
import 'providers/consumable_provider.dart';
import 'providers/app_auth_provider.dart';
import 'providers/telemetry_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/printer_connection_provider.dart';
import 'providers/spool_change_provider.dart';
import 'providers/personal_inventory_action_guard.dart';
import 'core/constants/personal_spool_policy.dart';
import 'providers/external_multicolor_plan_provider.dart';
import 'providers/farm_slice_intake_provider.dart';
import 'providers/print_queue_provider.dart';
import 'ui/aurora_shell.dart';
import 'ui/workspace_navigation.dart';
import 'ui/aurora_design.dart';
import 'widgets/confirm_dialog.dart';
import 'widgets/app_dialog.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/glass_card.dart';

/// 全局 Navigator key。
/// 供服务层（如换色提醒）在主窗口弹 Dialog，无需 BuildContext。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class ConsumableTrackerApp extends ConsumerStatefulWidget {
  const ConsumableTrackerApp({super.key});

  @override
  ConsumerState<ConsumableTrackerApp> createState() =>
      _ConsumableTrackerAppState();
}

class _ConsumableTrackerAppState extends ConsumerState<ConsumableTrackerApp>
    with WidgetsBindingObserver, WindowListener, TrayListener {
  bool _trayReady = false;
  bool _printerFaultDialogOpen = false;
  final Set<String> _notifiedFaults = {};
  bool _trayDialogOpen = false;
  bool _spoolChangeDialogOpen = false;
  bool _externalMulticolorDialogOpen = false;
  bool _farmSliceDialogOpen = false;
  bool _farmRemovalDialogOpen = false;
  bool _pendingWorkflowScheduled = false;
  bool _windowActive = true;
  Timer? _personalInventorySyncTimer;
  bool _personalInventorySyncRunning = false;
  final _updateNavigationObserver = AppUpdateNavigationObserver();
  final _startupUpdatePromptsReady = Completer<void>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initTray();
    // 初始化本地通知服务（Windows Toast 通知）
    ref.read(notificationServiceProvider).init();
    // Farm faults stay in the farm product's local/remote realm. The personal
    // fault API must never be started by a farm binary, even for an owner who
    // authenticates with a shared Sohun account.
    if (!AppVariant.isFarm) ref.read(printerFaultSyncServiceProvider);
    if (!AppVariant.isFarm) ref.read(deviceWorkbenchPublisherProvider);
    // 启动本地指标服务，并把四类问题线索接入可选的匿名诊断队列。
    // 上传开关仍默认关闭；未配置社区服务器时只保存在本地。
    unawaited(
      ref.read(telemetryServiceProvider.future).then((service) {
        ProductIssueCollector.attachTelemetry(service);
        CameraDiagnosticsTelemetry.attachTelemetry(service);
      }),
    );
    // P1-创新1: personal product drying reminders. Farm stock has its own
    // inventory lifecycle and must not be scanned by this personal service.
    if (!AppVariant.isFarm) {
      ref.read(dryingReminderServiceProvider).start();
    }
    // The farm product has its own inventory realm.  Do not start the
    // personal-account synchronizer (or its timer) in that binary, even when
    // an administrator signs in with a normal Sohun account to manage a farm.
    if (!AppVariant.isFarm) {
      unawaited(_syncPersonalInventoryAfterAuth());
      _personalInventorySyncTimer = Timer.periodic(
        const Duration(minutes: 2),
        (_) => unawaited(_syncPersonalInventoryAfterAuth()),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _showWhatsNewAfterStartup().whenComplete(() {
          if (!_startupUpdatePromptsReady.isCompleted) {
            _startupUpdatePromptsReady.complete();
          }
        }),
      );
      unawaited(
        ref
            .read(printerFleetConnectionManagerProvider.notifier)
            .monitorAllConfigured(),
      );
    });
  }

  Future<void> _showWhatsNewAfterStartup() async {
    final version = AppReleaseNotes.current.version;
    final onboardingCompleted = await OnboardingPrefs.isCompleted();
    if (!onboardingCompleted) {
      // 首次安装由初始化向导负责介绍产品，不叠加“更新内容”弹层。
      await ReleaseNotesPrefs.markSeen(version);
      return;
    }
    if (!await ReleaseNotesPrefs.shouldShow(version)) return;
    if (!mounted) return;

    final handoff = StartupHandoffScope.maybeRead(context);
    if (handoff?.isActive ?? false) await handoff!.completed;
    if (!mounted) return;
    if (ref.read(appUpdateRequiredProvider)) return;
    final dialogContext = navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    await WhatsNewDialog.show(dialogContext);
    await ReleaseNotesPrefs.markSeen(version);
  }

  /// Pulls account-scoped rolls while the desktop app is open so a phone
  /// write becomes visible without requiring a manual restart. The service
  /// merges local edits and uses the server revision as an optimistic lock.
  Future<void> _syncPersonalInventoryAfterAuth() async {
    if (AppVariant.isFarm || !mounted || _personalInventorySyncRunning) return;
    final authNotifier = ref.read(appAuthProvider.notifier);
    await authNotifier.ready;
    if (!mounted) return;
    final auth = ref.read(appAuthProvider);
    final session = auth.session;
    final api = ref.read(communityApiProvider);
    if (session == null ||
        session.authRealm != 'personal' ||
        api is! PersonalInventoryApi) {
      return;
    }
    _personalInventorySyncRunning = true;
    try {
      // Access tokens are short-lived. Refresh through the existing auth
      // notifier before the snapshot merge so the background timer and a
      // phone-created record keep working after the initial login window.
      final validSession = await authNotifier.ensureValidSession();
      final result = await PersonalInventorySyncService(
        dao: ref.read(consumableDaoProvider),
        api: api as PersonalInventoryApi,
      ).synchronize(session: validSession);
      if (result.importedCount > 0) {
        debugPrint(
          '个人库存同步完成：导入 ${result.importedCount} 条，revision=${result.remoteRevision}',
        );
      }
    } catch (error) {
      // Background sync must not block the workbench. The next timer tick or
      // window activation retries with the same account snapshot.
      debugPrint('个人库存同步失败：$error');
    } finally {
      _personalInventorySyncRunning = false;
    }
  }

  Future<void> _showPendingSpoolChanges() async {
    final farmMode = ref.read(studioModeEnabledProvider);
    if (_spoolChangeDialogOpen ||
        _farmRemovalDialogOpen ||
        _externalMulticolorDialogOpen ||
        (!farmMode &&
            ref
                .read(externalMulticolorPlanQueueProvider)
                .any((request) => !request.farmMode)) ||
        ref
            .read(spoolChangeQueueProvider.notifier)
            .pendingForMode(farmMode)
            .isEmpty ||
        !mounted) {
      return;
    }
    _spoolChangeDialogOpen = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      final handoff = StartupHandoffScope.maybeRead(context);
      if (handoff?.isActive ?? false) await handoff!.completed;
      if (!mounted ||
          ref
              .read(spoolChangeQueueProvider.notifier)
              .pendingForMode(farmMode)
              .isEmpty ||
          ref.read(studioModeEnabledProvider) != farmMode) {
        return;
      }

      await _showMainWindow();
      final dialogContext = navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      final pending = ref
          .read(spoolChangeQueueProvider.notifier)
          .pendingForMode(farmMode);
      if (!farmMode && pending.first.isRemoval) {
        await _handleDetectedPersonalRemoval(dialogContext, pending.first);
      } else if (ref.read(studioModeEnabledProvider)) {
        await FarmSpoolChangeConfirmationDialog.show(dialogContext);
      } else {
        await SpoolChangeConfirmationDialog.show(dialogContext);
      }
    } finally {
      _spoolChangeDialogOpen = false;
      _showNextPendingWorkflow();
    }
  }

  Future<void> _handleDetectedPersonalRemoval(
    BuildContext dialogContext,
    SpoolChangeObservation event,
  ) async {
    final queue = ref.read(spoolChangeQueueProvider.notifier);
    final dao = ref.read(printerDaoProvider);
    final guard = PersonalInventoryActionGuard.fromRef(ref);
    SpoolChangeObservation? currentAtLocation() => queue
        .pendingForMode(false)
        .where((item) => item.locationKey == event.locationKey)
        .firstOrNull;
    void resolveRemovalIfCurrent() {
      final current = currentAtLocation();
      if (current?.isRemoval == true) queue.resolve(current!.eventId);
    }

    void snoozeRemovalIfCurrent() {
      final current = currentAtLocation();
      if (current?.isRemoval == true) queue.snooze(current!);
    }

    try {
      final printerId =
          event.printerId ??
          await dao.getPrinterIdBySerial(event.printerSerial);
      if (printerId == null) {
        resolveRemovalIfCurrent();
        return;
      }
      final printer = await dao.getByIdWithChannels(printerId);
      if (!mounted || !dialogContext.mounted) return;
      final channel = printer?.channels
          .where((item) => item.channel.channelIndex == event.channelIndex)
          .firstOrNull;
      final consumable = channel?.consumable;
      if (channel == null || consumable == null) {
        resolveRemovalIfCurrent();
        return;
      }
      guard.assertCurrent();
      final initialAccountScope = guard.scope;
      if (initialAccountScope.enforce &&
          !await ref
              .read(consumableDaoProvider)
              .ensurePersonalConsumableAccess(
                consumable.id,
                ownerAccount: initialAccountScope.ownerAccount,
              )) {
        resolveRemovalIfCurrent();
        return;
      }
      // 用户已经从软件中选择过“维修暂取”，物理拔料不应再打扰一次。
      if (channel.farmRollPaused) {
        resolveRemovalIfCurrent();
        return;
      }

      // Freeze before asking the reason. Reusable CUID/FUID media use local
      // hold state 2, which requires an explicit physical-roll choice while
      // leaving the cloud-synced lifecycle active.
      final provisionalPause = consumable.remainingGrams > 0;
      if (provisionalPause) {
        await guard.run(
          consumable.id,
          () => dao.preparePersonalSpoolReplacement(
            channel.channel.id,
            expectedConsumableId: consumable.id,
            enforcePersonalOwner: initialAccountScope.enforce,
            personalOwnerAccount: initialAccountScope.ownerAccount,
          ),
        );
      }
      if (!mounted || !dialogContext.mounted) return;

      var stateChangedWhileOpen = false;
      final removalSubscription = ref
          .listenManual<List<SpoolChangeObservation>>(
            spoolChangeQueueProvider,
            (_, next) {
              final current = next
                  .where((item) => item.locationKey == event.locationKey)
                  .firstOrNull;
              if (current?.isRemoval != true &&
                  dialogContext.mounted &&
                  Navigator.of(dialogContext).canPop()) {
                stateChangedWhileOpen = true;
                Navigator.of(dialogContext).pop();
              }
            },
          );
      PersonalSpoolRemovalDecision? decision;
      try {
        decision = await PersonalSpoolRemovalDialog.showDetected(
          context: dialogContext,
          channelLabel: event.slotLabel,
          spoolLabel:
              '${consumable.manufacturer} · ${consumable.colorName ?? consumable.colorHex} · ${consumable.materialType}',
          remainingGrams: consumable.remainingGrams,
        );
      } finally {
        removalSubscription.close();
      }
      if (!mounted) return;
      if (decision == null) {
        final current = queue
            .pendingForMode(false)
            .where((item) => item.locationKey == event.locationKey)
            .firstOrNull;
        if (stateChangedWhileOpen || current?.isRemoval != true) return;
        queue.snooze(event);
        if (dialogContext.mounted) {
          showSnack(
            dialogContext,
            '已保留当前克数；CUID/FUID 装回后需确认具体余料卷',
            tone: AppNoticeTone.warning,
          );
        }
        return;
      }

      final channelId = channel.channel.id;
      guard.assertCurrent();
      final accountScope = guard.scope;
      switch (decision) {
        case PersonalSpoolRemovalDecision.maintenance:
          if (provisionalPause) {
            await guard.run(
              consumable.id,
              () => dao.resumePreparedPersonalSpoolReplacement(
                channelId,
                expectedConsumableId: consumable.id,
                keepPaused: true,
                enforcePersonalOwner: accountScope.enforce,
                personalOwnerAccount: accountScope.ownerAccount,
              ),
            );
          }
          if (dialogContext.mounted) {
            showSnack(
              dialogContext,
              canReusePersonalSpool(consumable.remainingGrams)
                  ? '已保留当前克数；维修完成后装回原卷即可继续'
                  : '已保留当前克数；余量需大于 30g 才能继续使用',
              tone: AppNoticeTone.warning,
            );
          }
        case PersonalSpoolRemovalDecision.takeOff:
          // The detection flow freezes this channel before opening the
          // reason dialog. A confirmed return-to-stock must be allowed to
          // clear that provisional freeze while preserving the exact grams.
          await guard.run(
            consumable.id,
            () => dao.unbindChannel(
              channelId,
              confirmDetectedRemoval: true,
              expectedConsumableId: consumable.id,
              enforcePersonalOwner: accountScope.enforce,
              personalOwnerAccount: accountScope.ownerAccount,
            ),
          );
          if (dialogContext.mounted) {
            showSnack(dialogContext, '已正常取下并保留余量；装回时请选择具体卷');
          }
        case PersonalSpoolRemovalDecision.usedUp:
          if (!mounted || !dialogContext.mounted) return;
          final confirmed = await AppDialog.confirm(
            dialogContext,
            '确认耗材已经用完？',
            '确认后会按耗尽结算并清空当前料位，库存记录将无法恢复。',
            confirmText: '确认用完',
            destructive: true,
          );
          if (!confirmed || !mounted) {
            snoozeRemovalIfCurrent();
            if (dialogContext.mounted) {
              showSnack(
                dialogContext,
                '已保留当前克数，稍后会再次询问如何处理',
                tone: AppNoticeTone.warning,
              );
            }
            return;
          }
          if (currentAtLocation()?.isRemoval != true) {
            if (dialogContext.mounted) {
              showSnack(
                dialogContext,
                '已检测到耗材重新装入，本次未执行耗尽结算',
                tone: AppNoticeTone.warning,
              );
            }
            return;
          }
          void assertRemovalStillCurrent() {
            final currentScope = ref.read(
              personalInventoryAccountScopeProvider,
            );
            if (currentScope.enforce != initialAccountScope.enforce ||
                currentScope.ownerAccount != initialAccountScope.ownerAccount) {
              throw StateError('账号已经切换，本次耗尽结算未执行');
            }
            if (currentAtLocation()?.isRemoval != true) {
              throw StateError('已检测到耗材重新装入，本次耗尽结算未执行');
            }
          }

          await dao.attachedDatabase.transaction(() async {
            assertRemovalStillCurrent();
            await dao.finishChannel(
              channelId,
              expectedConsumableId: consumable.id,
              confirmDetectedRemoval: provisionalPause,
              enforcePersonalOwner: initialAccountScope.enforce,
              personalOwnerAccount: initialAccountScope.ownerAccount,
            );
            assertRemovalStillCurrent();
          });
          if (dialogContext.mounted) {
            showSnack(dialogContext, '已按耗尽结算并清空料位');
          }
        case PersonalSpoolRemovalDecision.replace:
          if (dialogContext.mounted) {
            showSnack(
              dialogContext,
              '已保留旧卷记录，装入新卷后会继续询问绑定',
              tone: AppNoticeTone.info,
            );
          }
      }
      resolveRemovalIfCurrent();
    } catch (error) {
      snoozeRemovalIfCurrent();
      if (dialogContext.mounted) {
        showSnack(dialogContext, '处理拔料状态失败：$error', error: true);
      }
    }
  }

  Future<void> _showPendingExternalMulticolorPlans() async {
    if (_externalMulticolorDialogOpen ||
        _spoolChangeDialogOpen ||
        _farmRemovalDialogOpen ||
        ref.read(studioModeEnabledProvider) ||
        !ref
            .read(externalMulticolorPlanQueueProvider)
            .any((request) => !request.farmMode) ||
        !mounted) {
      return;
    }
    _externalMulticolorDialogOpen = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final handoff = StartupHandoffScope.maybeRead(context);
      if (handoff?.isActive ?? false) await handoff!.completed;
      final requests = ref
          .read(externalMulticolorPlanQueueProvider)
          .where((request) => !request.farmMode)
          .toList(growable: false);
      if (!mounted || requests.isEmpty || ref.read(studioModeEnabledProvider)) {
        return;
      }

      await _showMainWindow();
      final dialogContext = navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      await ExternalMulticolorPlanDialog.show(dialogContext, requests.first);
    } finally {
      _externalMulticolorDialogOpen = false;
      _showNextPendingWorkflow();
    }
  }

  /// 显示农场人工取件确认。等待取件来自数据库快照，因此应用重启后仍会
  /// 继续提醒；多台设备同时完成时按完成顺序逐台处理。
  Future<void> _showPendingFarmPrintRemovals() async {
    final pending =
        ref.read(pendingPrintRemovalsProvider).valueOrNull ?? const [];
    if (_farmRemovalDialogOpen ||
        _spoolChangeDialogOpen ||
        _externalMulticolorDialogOpen ||
        _farmSliceDialogOpen ||
        _trayDialogOpen ||
        ref.read(farmWorkOrderComposerActiveProvider) ||
        !ref.read(studioModeEnabledProvider) ||
        !ref.read(appAuthProvider).isSignedIn ||
        pending.isEmpty ||
        !mounted) {
      return;
    }
    _farmRemovalDialogOpen = true;
    try {
      final handoff = StartupHandoffScope.maybeRead(context);
      if (handoff?.isActive ?? false) await handoff!.completed;
      if (!mounted ||
          !ref.read(studioModeEnabledProvider) ||
          !ref.read(appAuthProvider).isSignedIn) {
        return;
      }
      final refreshed =
          ref.read(pendingPrintRemovalsProvider).valueOrNull ?? const [];
      if (refreshed.isEmpty) return;

      await _showMainWindow();
      final dialogContext = navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      await FarmPrintRemovalConfirmationDialog.show(
        dialogContext,
        item: refreshed.first,
        pendingCount: refreshed.length,
      );
    } finally {
      _farmRemovalDialogOpen = false;
      _showNextPendingWorkflow();
    }
  }

  /// 串行安排所有全局业务弹窗，防止打印完成、换卷和切片导入同时叠层。
  void _showNextPendingWorkflow() {
    if (!mounted || _pendingWorkflowScheduled) return;
    _pendingWorkflowScheduled = true;
    scheduleMicrotask(() {
      _pendingWorkflowScheduled = false;
      _dispatchNextPendingWorkflow();
    });
  }

  void _dispatchNextPendingWorkflow() {
    if (!mounted ||
        _printerFaultDialogOpen ||
        _farmRemovalDialogOpen ||
        _spoolChangeDialogOpen ||
        _externalMulticolorDialogOpen ||
        _farmSliceDialogOpen ||
        _trayDialogOpen) {
      return;
    }
    final farmMode = ref.read(studioModeEnabledProvider);
    if (ref.read(printerFaultPopupsEnabledProvider) &&
        ref.read(printerFaultMonitorProvider).pending.isNotEmpty) {
      unawaited(_showPendingPrinterFaults());
      return;
    }
    final removalPending =
        ref.read(pendingPrintRemovalsProvider).valueOrNull?.isNotEmpty == true;
    if (farmMode &&
        ref.read(appAuthProvider).isSignedIn &&
        !ref.read(farmWorkOrderComposerActiveProvider) &&
        removalPending) {
      unawaited(_showPendingFarmPrintRemovals());
      return;
    }
    if (ref
        .read(spoolChangeQueueProvider.notifier)
        .pendingForMode(farmMode)
        .isNotEmpty) {
      unawaited(_showPendingSpoolChanges());
      return;
    }
    if (!farmMode &&
        ref
            .read(externalMulticolorPlanQueueProvider)
            .any((request) => !request.farmMode)) {
      unawaited(_showPendingExternalMulticolorPlans());
      return;
    }
    if (farmMode &&
        !ref.read(farmWorkOrderComposerActiveProvider) &&
        ref.read(farmSliceIntakeProvider).pending.isNotEmpty) {
      unawaited(_showPendingFarmSlices());
    }
  }

  Future<void> _showPendingPrinterFaults() async {
    if (_printerFaultDialogOpen || !mounted) return;
    _printerFaultDialogOpen = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      final handoff = StartupHandoffScope.maybeRead(context);
      if (handoff?.isActive ?? false) await handoff!.completed;
      if (!mounted) return;
      final ids = ref
          .read(printerFaultMonitorProvider)
          .pending
          .map((r) => r.eventId)
          .toSet();
      if (ids.isEmpty) return;
      final dialogContext = navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      await showPrinterFaultPopup(dialogContext, ids);
      if (mounted)
        await ref.read(printerFaultMonitorProvider.notifier).markRead(ids);
    } finally {
      _printerFaultDialogOpen = false;
      if (mounted) _showNextPendingWorkflow();
    }
  }

  Future<void> _showPendingFarmSlices() async {
    if (_farmSliceDialogOpen ||
        _farmRemovalDialogOpen ||
        !ref.read(studioModeEnabledProvider) ||
        ref.read(farmWorkOrderComposerActiveProvider) ||
        _spoolChangeDialogOpen ||
        _externalMulticolorDialogOpen ||
        ref
            .read(spoolChangeQueueProvider.notifier)
            .pendingForMode(true)
            .isNotEmpty ||
        ref.read(farmSliceIntakeProvider).pending.isEmpty ||
        !mounted) {
      return;
    }
    _farmSliceDialogOpen = true;
    final request = ref.read(farmSliceIntakeProvider).pending.first;
    try {
      final handoff = StartupHandoffScope.maybeRead(context);
      if (handoff?.isActive ?? false) await handoff!.completed;
      if (!mounted) return;
      await _showMainWindow();
      // Bambu Studio stays in the foreground while the intake decision is
      // made. Resetting this after the modal closes avoids pinning Sohun.
      await windowManager.setAlwaysOnTop(true);
      final dialogContext = navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      final action = await showFarmSlicePrompt(
        dialogContext,
        request.inspection,
      );
      if (!mounted || !dialogContext.mounted) return;
      switch (action) {
        case FarmSlicePromptAction.ignore:
          ref.read(farmSliceIntakeProvider.notifier).ignore(request.id);
        case FarmSlicePromptAction.later:
        case null:
          ref.read(farmSliceIntakeProvider.notifier).defer(request.id);
        case FarmSlicePromptAction.use:
          final saved = await showFarmWorkOrderDialog(
            dialogContext,
            initialInspections: [request.inspection],
          );
          if (saved) {
            ref.read(farmSliceIntakeProvider.notifier).complete(request.id);
          } else {
            ref.read(farmSliceIntakeProvider.notifier).defer(request.id);
          }
      }
    } finally {
      try {
        await windowManager.setAlwaysOnTop(false);
      } catch (_) {}
      _farmSliceDialogOpen = false;
      _showNextPendingWorkflow();
    }
  }

  Future<void> _initTray() async {
    try {
      await _syncThemeIcons(force: true);
      await trayManager.setToolTip(AppIdentity.trayTooltip);
      _trayReady = true;
      await _refreshTrayMenu();
    } catch (_) {
      _trayReady = false;
      // 托盘初始化失败不阻塞应用启动
    }
  }

  Future<void> _refreshTrayMenu() async {
    if (!_trayReady) return;
    final activePrinter = ref.read(activePrinterConnectionProvider);
    final activeConfig = ref.read(activePrinterConfigProvider);
    final status = activePrinter.status;
    final gcodeState = status?.gcodeState;
    final isPrinting =
        gcodeState == BambuGcodeState.running ||
        gcodeState == BambuGcodeState.pause;
    final paused = gcodeState == BambuGcodeState.pause;
    final progress = (status?.mcPercent ?? 0).clamp(0, 100);
    final printerLabel = activeConfig?.displayLabel.trim().isNotEmpty == true
        ? activeConfig!.displayLabel
        : 'sohun · 暂无活跃打印机';
    final statusLabel = !activePrinter.isConnected
        ? '未连接'
        : paused
        ? '已暂停 · $progress%'
        : isPrinting
        ? '打印中 · $progress%'
        : '已连接 · 待命';
    final menu = buildAppTrayMenu(
      printerLabel: printerLabel,
      statusLabel: statusLabel,
      canTogglePrint: isPrinting,
      printPaused: paused,
      onOpenWorkspace: () =>
          unawaited(_openWorkspacePageFromTray(WorkspacePageIds.dashboard)),
      onOpenInventory: () =>
          unawaited(_openWorkspacePageFromTray(WorkspacePageIds.inventory)),
      onOpenPrinters: () =>
          unawaited(_openWorkspacePageFromTray(WorkspacePageIds.printers)),
      onTogglePrint: () => _togglePrintFromTray().ignore(),
      onOpenSettings: () => unawaited(_openSettingsFromTray()),
      onExit: () => unawaited(_exitApp()),
    );
    await trayManager.setContextMenu(menu);
  }

  Future<void> _showMainWindow() async {
    _setWindowActive(true);
    try {
      await windowManager.show();
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.focus();
    } catch (_) {
      try {
        await windowManager.show();
      } catch (_) {}
    }
  }

  Future<void> _openWorkspacePageFromTray(String pageId) async {
    ref.read(workspaceNavigationRequestProvider.notifier).state = pageId;
    await _showMainWindow();
  }

  Future<bool> _togglePrintFromTray() async {
    final state = ref.read(activePrinterConnectionProvider).status?.gcodeState;
    final notifier = ref.read(activePrinterConnectionProvider.notifier);
    if (state == BambuGcodeState.pause) return notifier.resume();
    if (state == BambuGcodeState.running) return notifier.pause();
    return false;
  }

  Future<void> _openSettingsFromTray() async {
    await _showMainWindow();
    if (!mounted || _trayDialogOpen) return;
    final dialogContext = navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    _trayDialogOpen = true;
    try {
      await SettingsSheet.show(dialogContext);
    } finally {
      _trayDialogOpen = false;
      _showNextPendingWorkflow();
    }
  }

  Future<void> _showTrayMenu() async {
    try {
      await _refreshTrayMenu();
      await trayManager.popUpContextMenu();
    } catch (error) {
      debugPrint('显示原生托盘菜单失败: $error');
    }
  }

  Brightness _effectiveBrightness() {
    final mode = ref.read(themeModeProvider);
    if (mode == ThemeMode.dark) return Brightness.dark;
    if (mode == ThemeMode.light) return Brightness.light;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }

  Future<void> _syncThemeIcons({bool force = false}) async {
    try {
      await ref
          .read(themeIconServiceProvider)
          .apply(
            color: ref.read(themeColorProvider),
            brightness: _effectiveBrightness(),
            force: force,
          );
    } catch (error) {
      debugPrint('同步主题图标失败: $error');
    }
  }

  Future<void> _exitApp() async {
    // P0 修复：退出前清理资源，避免数据库未关闭、扣减 Future 未完成导致库存数据丢失
    try {
      // 等待 RollSnackCounter 中的未完成 Timer
      RollSnackCounter.instance.dispose();
    } catch (_) {}
    try {
      await ProductIssueCollector.markCleanShutdown();
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _setWindowActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed && !AppVariant.isFarm) {
      unawaited(_syncPersonalInventoryAfterAuth());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(ProductIssueCollector.markCleanShutdown());
    }
  }

  void _setWindowActive(bool active) {
    if (!mounted || _windowActive == active) return;
    setState(() => _windowActive = active);
  }

  @override
  void onWindowFocus() => _setWindowActive(true);

  @override
  void onWindowBlur() => _setWindowActive(false);

  @override
  void onWindowMinimize() => _setWindowActive(false);

  @override
  void onWindowRestore() => _setWindowActive(true);

  @override
  void didChangePlatformBrightness() {
    if (ref.read(themeModeProvider) == ThemeMode.system) {
      setState(() {});
      unawaited(_syncThemeIcons());
    }
  }

  @override
  void onWindowClose() async {
    if (!ref.read(closeToTrayProvider)) {
      await _exitApp();
      return;
    }
    // 默认关闭窗口 = 隐藏到托盘（后台运行）
    // P1 修复：hide 失败时 fallback 到 minimize，避免窗口状态不一致
    _setWindowActive(false);
    try {
      await windowManager.hide();
    } catch (_) {
      try {
        await windowManager.minimize();
      } catch (_) {}
    }
  }

  @override
  void onTrayIconMouseDown() {
    // 左键只恢复主软件，符合 Windows 桌面软件的常见行为。
    unawaited(_showMainWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键始终使用 Windows 原生菜单，保证 DPI/任务栏布局下可操作。
    unawaited(_showTrayMenu());
  }

  @override
  void dispose() {
    _personalInventorySyncTimer?.cancel();
    _personalInventorySyncTimer = null;
    _updateNavigationObserver.dispose();
    if (!_startupUpdatePromptsReady.isCompleted) {
      _startupUpdatePromptsReady.complete();
    }
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    // P1 修复：tray 未初始化成功时 destroy 可能抛异常，包 try-catch 避免 dispose 链中断
    try {
      trayManager.destroy();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(printerFaultPopupsEnabledProvider, (_, next) {
      if (next) _showNextPendingWorkflow();
    });
    ref.listen(printerFaultMonitorProvider, (_, next) {
      final fresh = next.pending
          .where((r) => _notifiedFaults.add('${r.eventId}:${r.severity}'))
          .toList();
      if (fresh.isNotEmpty) {
        final first = fresh.first;
        unawaited(
          ref
              .read(notificationServiceProvider)
              .alert(
                type: AlertType.printerFault,
                title: '${first.printerName} · 打印机提醒',
                body: first.message,
                onClick: () async {
                  await _showMainWindow();
                  _showNextPendingWorkflow();
                },
              ),
        );
      }
      _showNextPendingWorkflow();
    });
    final themeMode = ref.watch(themeModeProvider);
    // P1 修复：监听主题色变化，用 seed 重新生成 ThemeData。
    // 切换主题色后整棵树重建，所有 Material 组件 + 引用 AppColors.primary 的自定义组件立即变色。
    final themeColor = ref.watch(themeColorProvider);
    final interactionEffects = ref.watch(interactionEffectsEnabledProvider);
    ref.listen<bool>(closeToTrayProvider, (_, __) {
      unawaited(_refreshTrayMenu());
    });
    ref.listen<bool>(autostartEnabledProvider, (_, __) {
      unawaited(_refreshTrayMenu());
    });
    ref.listen<ThemeMode>(themeModeProvider, (_, __) {
      unawaited(_syncThemeIcons());
    });
    ref.listen(themeColorProvider, (_, __) {
      unawaited(_syncThemeIcons());
    });
    ref.listen<List<SpoolChangeObservation>>(spoolChangeQueueProvider, (_, __) {
      _showNextPendingWorkflow();
    });
    ref.listen<List<ExternalMulticolorPlanRequest>>(
      externalMulticolorPlanQueueProvider,
      (_, __) {
        _showNextPendingWorkflow();
      },
    );
    ref.listen(pendingPrintRemovalsProvider, (_, __) {
      _showNextPendingWorkflow();
    });
    ref.listen<AppAuthState>(appAuthProvider, (_, next) {
      if (next.isSignedIn) {
        _showNextPendingWorkflow();
        if (!AppVariant.isFarm) {
          unawaited(_syncPersonalInventoryAfterAuth());
        }
      }
    });
    ref.listen<bool>(studioModeEnabledProvider, (_, __) {
      _showNextPendingWorkflow();
    });
    ref.listen<FarmSliceIntakeState>(farmSliceIntakeProvider, (_, __) {
      _showNextPendingWorkflow();
    });
    ref.listen<bool>(farmWorkOrderComposerActiveProvider, (_, active) {
      if (!active) _showNextPendingWorkflow();
    });
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final useDark =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            platformBrightness == Brightness.dark);
    Aurora.applyTheme(primaryColor: themeColor.seed, dark: useDark);
    final studioMode = ref.watch(studioModeEnabledProvider);
    final allowOptionalUpdatePrompts =
        ref.watch(onboardingCompletedProvider).valueOrNull == true;
    return MaterialApp(
      title: AppIdentity.name,
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      navigatorObservers: [_updateNavigationObserver],
      theme: buildPersonalDesktopTheme(
        AppTheme.lightFrom(themeColor.seed, themeColor.accent),
        personalProduct: AppVariant.isPersonal,
        studioMode: studioMode,
      ),
      darkTheme: buildPersonalDesktopTheme(
        AppTheme.darkFrom(themeColor.seed, themeColor.accent),
        personalProduct: AppVariant.isPersonal,
        studioMode: studioMode,
      ),
      themeMode: themeMode,
      themeAnimationDuration: interactionEffects
          ? const Duration(milliseconds: 220)
          : Duration.zero,
      builder: (context, child) {
        final systemDisablesAnimations =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        return InteractionEffectsScope(
          enabled: interactionEffects && !systemDisablesAnimations,
          child: TickerMode(
            enabled: _windowActive,
            child: AppUpdateGate(
              navigationObserver: _updateNavigationObserver,
              initialCheckReady: () => ref.read(appAuthProvider.notifier).ready,
              optionalPromptsReady: _startupUpdatePromptsReady.future,
              allowOptionalPrompts: allowOptionalUpdatePrompts,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
      home: AppBackground(
        child: Consumer(
          builder: (context, ref, _) {
            final completed = ref.watch(onboardingCompletedProvider);
            return completed.when(
              loading: () => Column(
                children: [
                  const CustomTitleBar(),
                  Expanded(
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      body: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: AppColors.primary),
                            const SizedBox(height: 12),
                            const Text(
                              '正在加载…',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              data: (done) => Column(
                children: [
                  const CustomTitleBar(),
                  Expanded(
                    child: done
                        ? const AuroraWorkspace()
                        : const OnboardingWizard(),
                  ),
                ],
              ),
              error: (_, __) => const Column(
                children: [
                  CustomTitleBar(),
                  Expanded(child: AuroraWorkspace()),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
