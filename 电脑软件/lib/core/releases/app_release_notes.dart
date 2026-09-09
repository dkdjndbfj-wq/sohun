import '../app_version.dart';

enum AppReleaseNoteKind { appearance, account, workflow, performance }

class AppReleaseNote {
  const AppReleaseNote({
    required this.kind,
    required this.title,
    required this.description,
  });

  final AppReleaseNoteKind kind;
  final String title;
  final String description;
}

class AppReleaseNotes {
  const AppReleaseNotes({
    required this.version,
    required this.title,
    required this.summary,
    required this.items,
  });

  final String version;
  final String title;
  final String summary;
  final List<AppReleaseNote> items;

  static const current = AppReleaseNotes(
    version: AppVersion.fullVersion,
    title: '耗材卷追踪已经接成完整链路',
    summary: '资料卡可以反复入库，每一卷的装入、取下、余量与消耗都按实物保留。',
    items: [
      AppReleaseNote(
        kind: AppReleaseNoteKind.workflow,
        title: 'CUID/FUID 可重复入库',
        description: '读取资料卡后可选择新增卷数；每次入库生成独立库存卷，取消时不会改变库存。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.account,
        title: '个人库存严格隔离',
        description: '库存和消耗按服务器与账号身份保存，切换账号后不会看到或选到其他账号的耗材。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.workflow,
        title: '换卷会保留旧卷余量',
        description: '检测到取料或进料时先确认实际动作；未用完的旧卷回库并保留卷号、余量和消耗。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.performance,
        title: '标签职责更清楚',
        description: 'NTAG213 只用于设备工作台；CUID/FUID 的 NFC 恢复流程和异常提示也更加稳定。',
      ),
    ],
  );
}
