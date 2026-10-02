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
    title: '手机读卡与库存体验更新',
    summary: '读取首页更简洁，已有卡与新卡分开处理，居中弹窗和轻量导航让常用操作更清楚。',
    items: [
      AppReleaseNote(
        kind: AppReleaseNoteKind.appearance,
        title: '简洁读取首页',
        description: '首页保留一个读取按钮，自动显示 NFC 状态；已有资料卡与空白新卡进入不同的居中弹窗。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.appearance,
        title: '轻量 SVG 导航',
        description: '标签、库存、提醒与我的使用统一细线图标，浅色与深色主题保持一致。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.workflow,
        title: 'CUID/FUID 可重复入库',
        description: '核对品牌、材料类型和颜色后按卷数或克数入库；每卷固定 1000g，严格大于 30g 才能继续使用。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.workflow,
        title: '品牌与库存一致',
        description: '拓竹、Bambu 等别名统一识别，耗材类型不夹带品牌名；手机版与桌面版共享库存规则。',
      ),
      AppReleaseNote(
        kind: AppReleaseNoteKind.account,
        title: '个人库存严格隔离',
        description: '读卡与入库按当前账号处理，切换账号后不会将未完成的操作写入其他账号。',
      ),
    ],
  );
}
