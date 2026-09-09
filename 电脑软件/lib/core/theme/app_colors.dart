import 'package:flutter/material.dart';

/// 桌面端配色系统（v3 苹果毛玻璃版）。
///
/// 沿用极光绿主色（与"耗材统计"主题贴合），但在 v2 基础上：
/// - 明快色调：提升 primary 亮度与饱和度，更接近苹果系统绿。
/// - 立体玻璃质感：新增 glass 系列半透明填充 / 高光 / 边框 token。
/// - 光影层次：分层阴影（ambient 环境光 + key 主光 + rim 轮廓光）。
/// - 圆润曲线：加大圆角（卡片 20px、按钮 12px、胶囊 999）。
///
/// 保留 v1/v2 全部常量名以兼容 30+ 文件引用。
class AppColors {
  AppColors._();

  // ===== Primary（极光绿，v3 提亮版）=====
  // P1 修复：primary/accent/primaryContainer 等改为运行时可变 static 字段，
  // 由 ThemeColorNotifier 在启动和切换主题色时赋值。默认值保持极光绿。
  // 注意：不能再用 const，否则 ThemeColorNotifier 无法运行时覆盖。
  static Color primary = const Color(0xFF00B42A); // 极光绿
  // P2 修复：primary50/100/200/300/700 改为可变 static，由 ThemeColorNotifier._apply 派生
  static Color primary50 = const Color(0xFFECFDF5);
  static Color primary100 = const Color(0xFFD1FAE5);
  static Color primary200 = const Color(0xFFA7F3D0);
  static Color primary300 = const Color(0xFF6EE7B7);
  static Color primary400 = const Color(0xFF34D399);
  static Color primary500 = const Color(0xFF00B42A);
  static Color primary600 = const Color(0xFF009A24);
  static Color primary700 = const Color(0xFF047857);
  static Color primary800 = const Color(0xFF065F46);
  static Color primary900 = const Color(0xFF064E3B);
  static Color primaryContainer = const Color(0xFFD1FAE5);
  static Color onPrimary = Colors.white;
  static Color onPrimaryContainer = const Color(0xFF065F46);

  // ===== Accent（Teal 青绿，用于渐变副色）=====
  static Color accent = const Color(0xFF14B8A6);
  static Color accentContainer = const Color(0xFFF0FDFA);

  // ===== 背景 / 表面（苹果风格浅灰 + 暖白）=====
  /// 浅灰带绿调（v5 调整）：比纯冷灰更温暖，与极光绿主色更协调。
  static const Color bgBase = Color(0xFFF5F7F5);
  static const Color surface = Colors.white;
  static const Color surfaceDim = Color(0xFFE9ECEF);
  static const Color surfaceContainerLow = Color(0xFFF1F3F5);
  static const Color surfaceContainer = Colors.white;
  static const Color surfaceContainerHigh = Color(0xFFF8F9FA);
  static const Color surfaceContainerHighest = Color(0xFFF1F3F5);
  static const Color surfaceVariant = Color(0xFFF1F3F5);

  // ===== 选中态高亮色（v5 新增，参考 BambuStudio LIGHT_GREEN）=====
  /// 选中态浅绿背景：弹窗/列表项选中时使用。
  static Color lightGreen = const Color(0xFFDBFDE7);

  /// 卡片极淡绿色边框：rgba(29,200,134,0.08)
  static Color cardBorder = const Color(0x1400B42A);

  /// 原子更新所有会随主题变化的派生色，避免页面仍引用上一个主题的色阶。
  static void applyTheme(Color seed, Color accentColor) {
    primary = seed;
    accent = accentColor;
    primary50 = Color.lerp(seed, Colors.white, 0.88) ?? seed;
    primary100 = Color.lerp(seed, Colors.white, 0.75) ?? seed;
    primary200 = Color.lerp(seed, Colors.white, 0.55) ?? seed;
    primary300 = Color.lerp(seed, Colors.white, 0.30) ?? seed;
    primary400 = Color.lerp(seed, Colors.white, 0.12) ?? seed;
    primary500 = seed;
    primary600 = Color.lerp(seed, Colors.black, 0.15) ?? seed;
    primary700 = Color.lerp(seed, Colors.black, 0.30) ?? seed;
    primary800 = Color.lerp(seed, Colors.black, 0.45) ?? seed;
    primary900 = Color.lerp(seed, Colors.black, 0.60) ?? seed;
    primaryContainer = seed.withValues(alpha: 0.15);
    onPrimary = Colors.white;
    onPrimaryContainer = Color.lerp(seed, Colors.black, 0.35) ?? seed;
    accentContainer = accentColor.withValues(alpha: 0.14);
    lightGreen = seed.withValues(alpha: 0.13);
    cardBorder = seed.withValues(alpha: 0.08);
  }

  // ===== 玻璃质感 token（v3 新增）=====
  /// 标准玻璃填充：半透明白，配合 BackdropFilter 实现毛玻璃。
  static const Color glassFill = Color(0xA6FFFFFF); // 白 65%
  /// 深玻璃填充：更透明，用于悬浮层。
  static const Color glassFillStrong = Color(0xB3FFFFFF); // 白 70%
  /// 玻璃顶部高光：模拟光源从上方照射的边缘反光。
  static const Color glassHighlight = Color(0xB3FFFFFF); // 白 70%
  /// 玻璃底部阴影边：模拟折射暗边。
  static const Color glassShadowEdge = Color(0x14000000); // 黑 8%
  /// 玻璃细描边。
  static const Color glassBorder = Color(0x66FFFFFF); // 白 40%
  /// 玻璃深色描边（侧栏/顶栏与背景分离用）。
  static const Color glassBorderDark = Color(0x1A000000); // 黑 10%

  // ===== 玻璃二级填充（v5 简化：去掉 L3，统一为 L1/L2）=====
  /// L1 轻玻璃：侧边栏/顶栏。白 65%。
  static const Color glassFillL1 = Color(0xA6FFFFFF);

  /// L2 中玻璃：卡片/弹窗。白 85%（v5 提升：原 L3 合并到 L2）。
  static const Color glassFillL2 = Color(0xD9FFFFFF);

  /// L3 兼容别名（v5 废弃，指向 L2，避免 30+ 文件引用报错）。
  /// 后续重构应统一为 L2，废弃使用。
  static const Color glassFillL3 = glassFillL2;

  /// L1 轻玻璃（暗色）：深灰 65%。
  static const Color glassFillL1Dark = Color(0xA6282C34);

  /// L2 中玻璃（暗色）：深灰 85%。
  static const Color glassFillL2Dark = Color(0xD9282C34);

  /// L3 兼容别名（v5 废弃）。
  static const Color glassFillL3Dark = glassFillL2Dark;

  /// 玻璃描边（暗色）：白 8%。
  static const Color glassBorderDarkMode = Color(0x14FFFFFF);

  /// 玻璃顶部高光（暗色）：白 12%，比亮色弱。
  static const Color glassHighlightDark = Color(0x1FFFFFFF);

  // ===== 暗色模式 token（v4 新增）=====
  /// 暗色背景基底。
  static const Color bgBaseDark = Color(0xFF1C1F26);

  /// 暗色背景渐变副色。
  static const Color bgBaseDarkAccent = Color(0xFF14171C);

  /// 暗色表面。
  static const Color surfaceDark = Color(0xFF242830);

  /// 暗色次级容器背景。
  static const Color surfaceVariantDark = Color(0xFF2A2E36);

  /// 暗色表面容器高位。
  static const Color surfaceContainerHighDark = Color(0xFF2F343D);

  /// 暗色主文字。
  static const Color textPrimaryDark = Color(0xFFF2F2F7);

  /// 暗色副文字。
  static const Color textSecondaryDark = Color(0xFF98989F);

  /// 暗色三级文字。
  static const Color textTertiaryDark = Color(0xFF6C6C70);

  /// 暗色分割线：白 8%。
  static const Color dividerDark = Color(0x14FFFFFF);

  /// 暗色描边。
  static const Color outlineDark = Color(0x1FFFFFFF);

  /// 暗色阴影色（更深）。
  static const List<BoxShadow> shadow1Dark = [
    BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> shadow2Dark = [
    BoxShadow(color: Color(0x40000000), blurRadius: 10, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x38000000), blurRadius: 6, offset: Offset(0, 3)),
  ];
  static const List<BoxShadow> shadow3Dark = [
    BoxShadow(color: Color(0x4D000000), blurRadius: 24, offset: Offset(0, 0)),
    BoxShadow(color: Color(0x42000000), blurRadius: 12, offset: Offset(0, 6)),
  ];
  static const List<BoxShadow> shadow4Dark = [
    BoxShadow(color: Color(0x66000000), blurRadius: 48, offset: Offset(0, 0)),
    BoxShadow(color: Color(0x52000000), blurRadius: 20, offset: Offset(0, 12)),
  ];

  // ===== 文字 =====
  static const Color textPrimary = Color(0xFF1D1D1F); // 苹果 SF 文字黑
  static const Color textSecondary = Color(0xFF495057);
  static const Color textTertiary = Color(0xFF868E96);
  static const Color textMuted = Color(0xFFADB5BD);

  // ===== 分隔 / 边框 =====
  static const Color divider = Color(0xFFE9ECEF);
  static const Color outline = Color(0xFFDEE2E6);
  static const Color outlineVariant = Color(0xFFE9ECEF);
  static const Color border = Color(0xFFE9ECEF);

  // ===== 语义色（苹果风格明快色）=====
  static const Color success = Color(0xFF34C759); // 苹果 systemGreen
  static const Color successContainer = Color(0xFFE6FCF5);
  static const Color warning = Color(0xFFFF9F0A); // 苹果 systemOrange
  static const Color warningContainer = Color(0xFFFFF9DB);
  static const Color danger = Color(0xFFEF5350); // Material red 400，更柔和
  static const Color dangerContainer = Color(0xFFFFEBEE);
  static const Color info = Color(0xFF007AFF); // 苹果 systemBlue
  static const Color infoContainer = Color(0xFFE7F5FF);

  // ===== 库存状态色 =====
  static const Color stockFull = Color(0xFF34C759);
  static const Color stockMid = Color(0xFFFF9F0A);
  static const Color stockLow = Color(0xFFFF3B30);
  static const Color stockEmpty = Color(0xFFADB5BD);

  // ===== 通道状态 =====
  static const Color channelEmpty = Color(0xFFE9ECEF);
  static Color get channelActive => primary;

  // ===== 图表色（明快绿系 + 暖色点缀）=====
  static Color get chart1 => primary;
  static Color get chart2 => accent;
  static const Color chart3 = Color(0xFF06B6D4);
  static const Color chart4 = Color(0xFFFFCC00);
  static const Color chart5 = Color(0xFFFF8787);

  // ===== 阴影（苹果分层光影：ambient + key + rim）=====
  /// 1 级：细微浮起（列表项、chip）
  static const List<BoxShadow> shadow1 = [
    BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// 2 级：卡片标准（环境光 + 主光）
  static const List<BoxShadow> shadow2 = [
    BoxShadow(
      color: Color(0x12000000),
      blurRadius: 10,
      blurStyle: BlurStyle.normal,
      offset: Offset(0, 1),
    ), // ambient
    BoxShadow(
      color: Color(0x0F000000),
      blurRadius: 6,
      offset: Offset(0, 3),
    ), // key
  ];

  /// 3 级：悬浮卡片 / 弹窗（三层光影）
  static const List<BoxShadow> shadow3 = [
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 24,
      offset: Offset(0, 0),
    ), // ambient
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 12,
      offset: Offset(0, 6),
    ), // key
  ];

  /// 4 级：大弹窗 / 模态（最大浮起）
  static const List<BoxShadow> shadow4 = [
    BoxShadow(
      color: Color(0x1A000000),
      blurRadius: 48,
      offset: Offset(0, 0),
    ), // ambient
    BoxShadow(
      color: Color(0x17000000),
      blurRadius: 20,
      offset: Offset(0, 12),
    ), // key
  ];

  // ===== 简化阴影（v5 新增：仅 2 级，用于新组件）=====
  /// 卡片默认阴影（轻微悬浮）。
  static const List<BoxShadow> shadowCard = [
    BoxShadow(color: Color(0x0D000000), blurRadius: 8, offset: Offset(0, 2)),
  ];

  /// 弹窗/hover 阴影（深度弹出）。
  static const List<BoxShadow> shadowModal = [
    BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, 4)),
  ];

  // ===== 圆角（苹果风格：大圆角）=====
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 18;
  static const double radiusXl = 22;
  static const double radiusXxl = 28; // v3 新增：大卡片
  static const double radiusFull = 999; // v3 新增：胶囊

  // ===== 兼容旧引用 =====
  // 注意：seed/secondary 引用可变的 primary/accent，必须用 getter 保证运行时同步
  static Color get seed => primary;
  static Color get secondary => accent;
  static const Color tertiary = success;
}
