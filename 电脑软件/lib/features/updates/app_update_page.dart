import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_update_service.dart';
import '../../core/theme/interaction_effects.dart';
import '../../data/prefs/app_prefs.dart';
import '../../widgets/app_brand_icon.dart';
import '../../widgets/app_glass_button.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/personal_desktop_chrome.dart';
import 'app_update_dialog.dart';

/// Explicit checks remain available even after an optional version is skipped.
class AppUpdatePage extends ConsumerStatefulWidget {
  const AppUpdatePage({super.key});

  static Future<void> show(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/app-updates'),
          builder: (_) => const AppUpdatePage(),
        ),
      );

  @override
  ConsumerState<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends ConsumerState<AppUpdatePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref.read(appUpdateServiceProvider.notifier).checkForUpdates(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final update = ref.watch(appUpdateServiceProvider);
    final service = ref.read(appUpdateServiceProvider.notifier);
    final required = update.hasUpdate && update.isMandatory;
    return PopScope(
      canPop: !required,
      child: PersonalDesktopBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: const Text('软件更新'),
            automaticallyImplyLeading: !required,
          ),
          body: SafeArea(
            top: false,
            child: update.hasUpdate
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Center(
                      child: AppUpdatePanel(
                        update: update,
                        onDownload: service.openDownloadPage,
                        onRetry: service.checkForUpdates,
                        onLater: required
                            ? null
                            : () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          children: [
                            _UpdateCheckStatus(
                              update: update,
                              onCheck: service.checkForUpdates,
                            ),
                            const SizedBox(height: 16),
                            const AppUpdateReminderSetting(),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _UpdateCheckStatus extends StatelessWidget {
  const _UpdateCheckStatus({required this.update, required this.onCheck});
  final AppUpdateState update;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checking =
        update.isChecking || update.phase == AppUpdatePhase.checking;
    final failed = update.phase == AppUpdatePhase.failed;
    final latest = update.phase == AppUpdatePhase.upToDate;
    return GlassCard(
      padding: const EdgeInsets.all(28),
      borderRadius: BorderRadius.circular(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: AppBrandIcon(size: 64, radius: 17)),
          const SizedBox(height: 22),
          Text(
            checking
                ? '正在寻找新版本'
                : failed
                ? '暂时无法检查更新'
                : latest
                ? '你已是最新版本'
                : '让 sohun 保持更新',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: 23,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '当前版本 ${update.currentVersion}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          if (checking) ...[
            if (AppMotion.enabled(context))
              const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 14),
            const Text('正在连接更新服务…', textAlign: TextAlign.center),
          ] else ...[
            if (failed)
              UpdateMessage(
                message: update.message ?? '检查网络连接后再试一次。',
                error: true,
              )
            else
              Text(
                latest ? '已完成检查，目前没有需要安装的新版本。' : '检查版本信息，查看最新改进与修复。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
              ),
            const SizedBox(height: 20),
            AppGlassButton(
              key: const ValueKey('update-check'),
              onPressed: onCheck,
              icon: Icon(
                failed
                    ? Icons.refresh_rounded
                    : latest
                    ? Icons.check_circle_outline_rounded
                    : Icons.sync_rounded,
                size: 19,
              ),
              label: failed
                  ? '重新检查'
                  : latest
                  ? '再次检查'
                  : '检查更新',
            ),
          ],
          if (update.checkedAt != null) ...[
            const SizedBox(height: 16),
            Text(
              '上次检查 ${_checkedAt(update.checkedAt!)}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class AppUpdateReminderSetting extends ConsumerWidget {
  const AppUpdateReminderSetting({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => GlassCard(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('新版本提醒'),
      subtitle: const Text('自动提醒可选更新；必要更新仍会提示。'),
      value: ref.watch(autoCheckUpdatesProvider),
      onChanged: (value) =>
          ref.read(autoCheckUpdatesProvider.notifier).setEnabled(value),
    ),
  );
}

/// Compact settings entry: detailed notes, failures and install handoff live
/// in the same update center used on the phone.
class AppUpdateEntryCard extends ConsumerWidget {
  const AppUpdateEntryCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateServiceProvider);
    final theme = Theme.of(context);
    final checking =
        update.isChecking || update.phase == AppUpdatePhase.checking;
    final status = checking
        ? '正在检查…'
        : update.hasUpdate
        ? '${update.isMandatory ? '需要更新至' : '可更新至'} ${update.latestVersion}'
        : switch (update.phase) {
            AppUpdatePhase.upToDate => '已是最新版本',
            AppUpdatePhase.failed => '检查未完成，点击重试',
            _ => '查看版本信息与更新说明',
          };
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppBrandIcon(size: 40, radius: 11),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('软件更新', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      '当前版本 ${update.currentVersion}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            status,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: update.hasUpdate ? updateAccentColor(theme) : null,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: AppGlassButton(
              variant: AppGlassButtonVariant.secondary,
              onPressed: () => AppUpdatePage.show(context),
              icon: Icon(
                update.hasUpdate
                    ? Icons.system_update_alt_rounded
                    : Icons.sync_rounded,
                size: 17,
              ),
              label: update.hasUpdate ? '查看更新' : '检查更新',
            ),
          ),
        ],
      ),
    );
  }
}

String _checkedAt(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}
