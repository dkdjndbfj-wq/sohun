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
    title: '桌面窗口与安装体验焕新',
    summary: '安装、首次设置与日常工作台现在使用一致的窗口风格，资源打包也增加了完整性校验。',
    items: [
      AppReleaseNote(
        kind: AppReleaseNoteKind.appearance,
        title: '首次设置融入窗口',
        description: '移除内外双层边框，关闭、最小化和最大化按钮直接放进首次设置界面。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.appearance,
        title: '自定义标题栏更统一',
        description: '窗口控制改为 sohun 自有样式，不再显示割裂的 Windows 风格按钮行。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.workflow,
        title: '升级安装更可靠',
        description: '重复打开安装器只保留一个安装流程，并兼容已有个人版的原安装目录与卸载记录。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.performance,
        title: '图标与资源完整性门禁',
        description: '构建会校验 Material 图标字体、声明资源、插件和运行库，缺失时不再生成安装包。',
      ),
    ],
  );
}
